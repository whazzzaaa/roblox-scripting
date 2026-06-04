-- connected discord-github
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- modules
local JanitorService = require(ReplicatedStorage:WaitForChild("Janitor"))
-- ui
local Player = Players.LocalPlayer
local PlayerGui : BasePlayerGui = Player:WaitForChild("PlayerGui")
local InventoryUi : ScreenGui = PlayerGui:WaitForChild("InventoryUi")
local InfoPanel : Frame = InventoryUi:WaitForChild("Info")
local BaseWindow : Frame = InventoryUi:WaitForChild("Base")
local ActionPanel : Frame = BaseWindow:WaitForChild("ActionPanel")
-- constants
local GridSizeScaleX = 0.04545
local GridSizeScaleY = 0.2
local ColumnGrids = 22
local RowGrids = 5
--[[ WindowWidth = 0.574    704 in pixels
 	WindowHeight = 0.21    160 in pixels]]
local ItemTag = "InventoryGridItemFrame"
-- variables
local CurrentInfoItem
-- grid table
local Gridspace = {} -- the grid coordination table
-- a table of columns (x), each column (x) table with a row (y) of 5 grids
-- each grid stores 1 reference to the frame INSTANCE that is occupying the grid, or nil meaning its empty
-- this is way more performant than having to use ui collision and all that pixel math since grids are nice units
local FrameObjects = {} -- table to store the item frame data (called frameobj) of each item in inventory
-- uses the item unique ids for keys
-- the frameobjs are for linking the data of items with their ui item frames (again, using the item unique id)
-- helps set apart the ui stuff and the actual item logic
-- janitor object to help clean up unnecessary connections
local Obliterator = JanitorService.new()
-- info tool cam for the viewport frame in info panel
-- created at runtime since roblox hates existing camera instances
local InfoToolCam = Instance.new("Camera")
InfoToolCam.Name = "InfoToolCam"
InfoToolCam.CFrame = CFrame.new(-10.623, 1.9, 9.565) * CFrame.Angles(0, -math.pi/2, 0)
-- helper functions
local function RotateYTool(Model)
	-- rotates the model (y axis) in the info panel viewport continuously
	local Prime : BasePart = Model.PrimaryPart
	while Model do
		Model:PivotTo(Prime.CFrame * 
			CFrame.Angles(0, math.rad(5), 0)
		)
		task.wait(0.05)
	end
end

local function PositionRelativeToWindow(Position : Vector2)
	return Position - BaseWindow.AbsolutePosition
end

local function GetMousePosition()
	local MousePos = UIS:GetMouseLocation()
	return Vector2.new(MousePos.X, MousePos.Y - GuiService.TopbarInset.Height)
end

local function GetGridAbsSize()
	return Vector2.new(
		BaseWindow.AbsoluteSize.X * GridSizeScaleX,
		BaseWindow.AbsoluteSize.Y * GridSizeScaleY
	)
end

local function PositionToGrid(Position : Vector2)
	-- get mouse pos relative to the window
	local GridAbsSize = GetGridAbsSize()
	local RelativePosition = PositionRelativeToWindow(Position)
	-- add 1 to each rounded grid X and Y since the grid coordination starts at 1,1 and the rounded numbers can return < 1
	-- therefore giving us a grid that is 1 unit lower on each axis than where it should be
	local OriginalX = math.round(RelativePosition.X / GridAbsSize.X) + 1
	local OriginalY = math.round(RelativePosition.Y / GridAbsSize.Y) + 1
	-- clamp to make sure the frame is dropped within the window even when mouse is outside
	local GridX = math.clamp(
		OriginalX,
		1,
		ColumnGrids
	)
	local GridY = math.clamp(
		OriginalY,
		1,
		RowGrids
	)
	return Vector2.new(GridX, GridY)
end

local function GridToPosition(Grid : Vector2)
	-- again since grid coordination starts at 1,1 and that makes more sense than starting at 0
	Grid -= Vector2.one
	local GridAbsSize = GetGridAbsSize()
	return Vector2.new(
		Grid.X * GridAbsSize.X,
		Grid.Y * GridAbsSize.Y
	)
end

local function GetUiItemsAtMousePosition()
	local MousePos = GetMousePosition()
	return PlayerGui:GetGuiObjectsAtPosition(MousePos.X, MousePos.Y)
end

local function GetInventoryItemAtMouse()
	local UiItems = GetUiItemsAtMousePosition()

	if #UiItems == 0 then return end
	return UiItems[1]:HasTag(ItemTag) and UiItems[1] or nil
	-- this is kind of dangerous since there could be ui items at a higher zindex
end

local function GetOccupantsInArea(GridPosition, SizeX, SizeY)
	local Occupants = {}
	for x = GridPosition.X, GridPosition.X + SizeX - 1, 1 do
		for y = GridPosition.Y, GridPosition.Y + SizeY - 1, 1 do
			-- check whether the current grid X and then Y in the grid table exists 
			-- so we know if the frame is at least partly out of the window to not place the frame there sticking a part out of the base window
			if not Gridspace[x] or not Gridspace[x][y] then return nil end
			local CurrentOccupant = Gridspace[x][y].Occupant
			if CurrentOccupant == nil then continue end
			table.insert(Occupants,
				{
					X = x,
					Y = y,
					Occupant = CurrentOccupant
				}
			)
		end
	end
	return Occupants
end

local function SetOccupantsInArea(GridPosition, AreaSize, OccupantInstance) -- instance or nil
	if not GridPosition then return end
	local SizeX = AreaSize.X
	local SizeY = AreaSize.Y

	for x = GridPosition.X, GridPosition.X + SizeX - 1, 1 do
		for y = GridPosition.Y, GridPosition.Y + SizeY - 1, 1 do
			if not Gridspace[x] or not Gridspace[x][y] then return end
			Gridspace[x][y].Occupant = OccupantInstance
		end
	end
end

local function GetObjFromInstance(FrameInstance)
	for UID, Obj in FrameObjects do
		if Obj.Instance == FrameInstance then
			return Obj, UID
		end
	end
	return nil
end

-- module, handles the ui visual grid inventory stuff (placement, using, equipping, discarding, checking info) while also acting as a limiter
-- singleton since each player only has one inventory and therefore one ui module for it
local InvUiModule = {
	Cooldown = false -- to prevent spamming and therefore bugs with setting the occupants in the gridspace table
}

function InvUiModule:Init(Main)
	-- main is the inventory module housing both this module and the logic module that handles storing and interacting with the actual items
	-- the items in the logic module share a unique id with their own frame object stored in FrameObjects
	self.Main = Main
	-- init grid table
	for x = 1, ColumnGrids, 1 do
		Gridspace[x] = {}
		for y = 1, RowGrids, 1 do
			Gridspace[x][y] = {Occupant = nil}
			-- occupant will be unique instance of the grid frame object
		end
	end
	
	CAS:BindActionAtPriority("ClickMoveFrame", function(...)
		return self:ClickMoveFrame(...)
	end, false, 1, Enum.UserInputType.MouseButton1)
	
	CAS:BindAction("ClickShowActionPanel", function(...)
		return self:ClickShowActionPanel(...)
	end, false, Enum.UserInputType.MouseButton2)
	
	return self
end

function InvUiModule:ClickMoveFrame(ActionName, InputState)
	if InputState ~= Enum.UserInputState.End then return Enum.ContextActionResult.Pass end
	self:HideActionPanel()
	local ItemAtMouse = GetInventoryItemAtMouse()
	if not ItemAtMouse then return Enum.ContextActionResult.Pass end
	local FrameObj = GetObjFromInstance(ItemAtMouse)
	self:StartMoveFrame(FrameObj, self.Main.Logic:GetItemByUID(FrameObj.UID))
	return Enum.ContextActionResult.Sink
end

function InvUiModule:ClickShowActionPanel(ActionName, InputState)
	if InputState ~= Enum.UserInputState.End then return Enum.ContextActionResult.Pass end
	local ItemAtMouse = GetInventoryItemAtMouse()
	if ItemAtMouse then
		local FrameObj = GetObjFromInstance(ItemAtMouse)
		self:ShowActionPanel(FrameObj)
		return Enum.ContextActionResult.Sink
	end
	self:HideActionPanel()
	return Enum.ContextActionResult.Pass
end
-- shows the action panel on right click, allowing for item interactions such as use, equip and discard 
function InvUiModule:ShowActionPanel(FrameObj)
	-- return the mouse position, in scale relative to the base window
	local Position = PositionRelativeToWindow(GetMousePosition()) / BaseWindow.AbsoluteSize
	ActionPanel.Visible = true
	-- use and equip buttons visibility depend on the item so hide them for now
	ActionPanel.Use.Visible = false
	ActionPanel.Equip.Visible = false
	ActionPanel.Position = UDim2.fromScale(Position.X, Position.Y)
	-- add functionality to action buttons
	local Item = self.Main.Logic:GetItemByUID(FrameObj.UID)
	if not Item then return end
	local InfoCon = ActionPanel.Information.MouseButton1Down:Once(function()
		self:ShowInfoPanel(Item, true)
	end)
	local DiscardCon = ActionPanel.Discard.MouseButton1Down:Once(function()
		self:DiscardItem(FrameObj)
	end)
	-- either use or equip connection, based on item type (equipment or consumable)
	local UseOrEquip = Item:IsA("Weapon") and "Equip" or "Use"
	local Button = ActionPanel:FindFirstChild(UseOrEquip)
	Button.Visible = true

	local CurrentWeaponEquipped = self.Main.Logic.CurrentItemUID == FrameObj.UID
	if Item:IsA("Weapon") then
		Button.Text = CurrentWeaponEquipped and "Unequip" or "Equip"
	end
	
	local UseCon = Button.MouseButton1Down:Once(function()
		if Item:IsA("Weapon") then
			if CurrentWeaponEquipped then
				self.Main.Logic:Unequip()
			else
				self.Main.Logic:EquipUID(FrameObj.UID)
			end
			return
		end
		local UseSuccessful = Item:Use()
		if UseSuccessful then
			self:DiscardItem(FrameObj)
		end
	end)
	
	Obliterator:Add(UseCon, "Disconnect", "UseCon")	
	Obliterator:Add(InfoCon, "Disconnect", "InfoCon")
	Obliterator:Add(DiscardCon, "Disconnect", "DiscardCon")
end

function InvUiModule:ShowInfoPanel(Item, Show)
	if Obliterator:Get("CloseInfoCon") then
		Obliterator:Remove("CloseInfoCon")
	end
	-- boolean "show" is for toggling the info panel on or off
	local Viewport = InfoPanel:WaitForChild("ViewportFrame")
	local OldToolModel = Viewport:FindFirstChildOfClass("Model")
	if OldToolModel then
		OldToolModel:Destroy()
	end
	
	if Show == false then 
		InfoPanel.Visible = false
		CurrentInfoItem = nil
		return
	end
	-- sets the info panel texts to the item info
	local Name = Item.Name
	local Model = Item.UIData.ModelInstance:Clone()
	local Desc = Item.Desc
	InfoPanel.Visible = true
	InfoPanel.NameLabel.Text = Name
	InfoPanel.Desc.DescLabel.Text = Desc
	
	CurrentInfoItem = Item.UID
	-- viewport
	Viewport.CurrentCamera = InfoToolCam

	Model.Parent = Viewport
	
	Obliterator:Add(InfoPanel.Close.MouseButton1Down:Once(function()
		self:ShowInfoPanel(nil, false)
	end), "Disconnect", "CloseInfoCon")
	task.spawn(RotateYTool, Model)
end

function InvUiModule:HideActionPanel()
	ActionPanel.Visible = false
	-- calls janitor to cleanup action buttons connections
	Obliterator:RemoveList("InfoCon", "DiscardCon")
end

function InvUiModule:NewItemEntry(FrameObj)
	-- since UID is "universally unique" (HttpService:GenerateGUID()), suitable for item dupes
	FrameObjects[FrameObj.UID] = FrameObj
end
 --only works while its in the ui inventory for now
function InvUiModule:DiscardItem(FrameObj)
	if CurrentInfoItem == FrameObj.UID then
		self:ShowInfoPanel(nil, false)
	end
	-- set grid occupant
	SetOccupantsInArea(FrameObj.CurrentGridPos, FrameObj.GridSize, nil)
	-- inventory logic 
	self.Main.Logic:DiscardItem(FrameObj.UID)
	-- remove from the inventory ui
	FrameObj:Destroy()
	FrameObjects[FrameObj.UID] = nil
end

function InvUiModule:PlaceFrame(FrameObj)
	--[[
		given a frame obj, attempt to snap it to the desired area
		the process:
			check the area the frame that is attached to cursor for occupants
			extract the occupants and check if theres more than 1 unique occupants
			if theres only 1, swap that out so now the frame obj is placed there and we're relocating that one formerly there
			if theres none then place the frame obj there
			placing calculates the grid position in scale, relative to the base window and sets the position udim2 there
		returns true for success, false for failure
	]]
	if self.Cooldown == true then return end
	
	local FrameInstance = FrameObj.Instance
	local GridPosition = PositionToGrid(FrameInstance.AbsolutePosition)
	
	local OccupantsInArea = GetOccupantsInArea(GridPosition, FrameObj.GridSize.X, FrameObj.GridSize.Y)
	if not OccupantsInArea then return false end
	
	local OccupantInstances = {}
	for _, Table in OccupantsInArea do
		-- check for unique item frames taking up each grid
		if Table.Occupant and not table.find(OccupantInstances, Table.Occupant) then
			table.insert(OccupantInstances, Table.Occupant)
		end
	end
	-- table OccupantInstances is used to get how many unique items are taking up
	-- the area the player is attempting to place the current item frame
	-- this is to check whether theres only 1 item so that players can swap that item out then place the desired item there
	if #OccupantInstances > 1 then return false end
	local _, FrameUnder = next(OccupantInstances)
	local FrameObjUnder = GetObjFromInstance(FrameUnder)
	if FrameUnder then
		SetOccupantsInArea(FrameObjUnder.CurrentGridPos, FrameObjUnder.GridSize, nil)
	end
	
	SetOccupantsInArea(GridPosition, FrameObj.GridSize, FrameInstance)
	FrameObj.CurrentGridPos = GridPosition
	-- set position
	local RoundedPos = GridToPosition(GridPosition)
	FrameInstance.Parent = BaseWindow
	FrameObj:ToScaleSize()
	FrameInstance.Position = UDim2.fromScale(
		RoundedPos.X/BaseWindow.AbsoluteSize.X,
		RoundedPos.Y/BaseWindow.AbsoluteSize.Y
	)

	return true, FrameObjUnder
end

function InvUiModule:StartMoveFrame(FrameObj, NewItem, RepositionFrameUnder)
	-- verify
	if self.Cooldown == true then return end
	
	FrameObj.Instance.ZIndex += 1  
	FrameObj.Instance.Parent = InventoryUi
	FrameObj:ToAbsoluteScaleSize()
	-- attach item frame to cursor every frame (RunService.PreRender)
	-- and empty its old area in the gridspace
	local PosUpdateConn : RBXScriptConnection = FrameObj:AttachToCursor()
	if not RepositionFrameUnder then
		SetOccupantsInArea(FrameObj.CurrentGridPos, FrameObj.GridSize, nil)
	end
	-- attempt placement 
	CAS:BindActionAtPriority("PlaceFrame", 
		function(_, State)
			if State ~= Enum.UserInputState.End then return Enum.ContextActionResult.Pass end  -- prevent both left mouse up and down trigger
			local PlaceSuccess, FrameUnder = self:PlaceFrame(FrameObj)
			if PlaceSuccess then
				FrameObj.Instance.ZIndex -= 1
				-- communicate with inventory to add this item
				self.Main.Logic:AddItem(NewItem, NewItem.UID)
				
				PosUpdateConn:Disconnect()
				CAS:UnbindAction("PlaceFrame")
				if FrameUnder then
					self:StartMoveFrame(FrameUnder, self.Main.Logic:GetItemByUID(FrameUnder.UID), true)
					return Enum.ContextActionResult.Sink
				end
				self:StartCooldown()
			end
			-- since we dont want to also pick up the item where placement is attempted
			-- (prevent ClickMoveFrame from calling while player is still trying to place the item frame)
			return Enum.ContextActionResult.Sink
		end
	, false, 2, Enum.UserInputType.MouseButton1)
end

function InvUiModule:StartCooldown()
	self.Cooldown = true
	task.delay(0.25, function()
		self.Cooldown = false
	end)
end

return InvUiModule
