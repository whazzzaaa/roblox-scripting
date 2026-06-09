-- connected discord-github
-- grid inventory system mainly inspired by system shock 2 (hidden gem, check it out)
-- manages the whole ui thing of the inventory like placing dragging interactions like using/equipping discarding and showing info
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
local AbsoluteGridXScale = 0.0261
local AbsoluteGridYScale = 0.0399
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
	-- works by adding an increment of 5deg rotation to the y rotation of the model in a loop
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
	-- GetMouseLocation returns the mouse location within the screen area below the topbar so subtract it
	-- we do this since we're working with absolute ui properties (not accounting for the topbar, relative to the corner of the device screen)
	-- therefore keeping the mousepos within the area inset by the topbar, for example, the code would consider the cursor being outside the window
	-- while on the screen the cursor is within the window and only near the lower border
	return Vector2.new(MousePos.X, MousePos.Y - GuiService.TopbarInset.Height)
end

local function GetGridAbsSize()
	-- grid size is scalar to the inventory window size
	-- so we get the absolute size (in vector2) of each grid by multiplying the scale size with absolute size of the inventory window
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
	-- given a grid coordination, return a vector2 of its position (in pixels/offest) relative to the inventory window's top left corner 
	-- since we're returning a position relative to the inventory window, we have to subtract (1,1) to the grid input
	-- because grid coordination starts at (1,1) and that would be (0,0) in the relative position
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
	-- UiItems is an array sorted by appearing order front > back so [1] -> [...]
	-- therefore we gotta iterate instead of doing specific indexing
	local UiItems = GetUiItemsAtMousePosition()

	if #UiItems == 0 then return nil end
	for _, Item in ipairs(UiItems) do
		if Item:HasTag(ItemTag) then return Item end
	end
	return nil
end

local function GetOccupantsInArea(GridPosition, SizeX, SizeY)
	-- given a grid coordinate, x and y size (like a rectangle), return a table with the grids that are occupied
	-- if the rectangle reaches outside the inventory window then return nil
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

local function SetOccupantsInArea(GridPosition, AreaSize, OccupantInstance)
	-- given a grid coordinate position and size of a grid area, set all of the occupants inside the grid area to OccupantInstance or nil (empty)
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
	-- given a frame instance, return the frameobj with that specific instance since each frameobj item (table) has a reference to that instance
	for UID, Obj in FrameObjects do
		if Obj.Instance == FrameInstance then
			return Obj, UID
		end
	end
	return nil
end

-- itemframe/frameobj class
-- represents the ui component of an item for positionin within the grid inventory window
-- each of these stores the ui instance (frame) and data for grid placement, cursor attachment (positioning) and scale resizing for
-- different contexts (dragging around, fully placed in the window)

local ItemFrame = {}
ItemFrame.__index = ItemFrame

function ItemFrame.NewFrame(ItemData, UID)
	-- given a table of item data (with its frame gridsize and imageid) and its uid, construct a new itemframe/frameobj object
	-- starts out parented to none so its set to the inventory screen gui first for placement
	local X, Y = ItemData.GridSize.X, ItemData.GridSize.Y

	local FrameInstance : ImageLabel = Instance.new("ImageLabel")

	local RatioConstraint = Instance.new("UIAspectRatioConstraint")
	RatioConstraint.Parent = FrameInstance
	RatioConstraint.AspectRatio = X/Y
	-- ui stuff
	local GridAbsSize = GetGridAbsSize()
	FrameInstance.Size = UDim2.fromOffset(
		GridAbsSize.X * X, GridAbsSize.Y * Y
	)
	FrameInstance.Position = UDim2.new()
	FrameInstance.Interactable = false
	FrameInstance.ZIndex = 5
	FrameInstance:AddTag(ItemTag)
	FrameInstance.BorderSizePixel = 0
	FrameInstance.BackgroundTransparency = .9
	-- set image
	FrameInstance.Image = ItemData.ImageId
	-- constructing data object
	local NewItemFrame = {}
	NewItemFrame.Instance = FrameInstance
	NewItemFrame.GridSize = Vector2.new(X, Y)
	NewItemFrame.AttachOffset = Vector2.new(FrameInstance.AbsoluteSize.X/2, FrameInstance.AbsoluteSize.Y/2) -- since pivot is top left and we need that for the grid stuff
	NewItemFrame.UID = UID

	return setmetatable(NewItemFrame, ItemFrame)
end

function ItemFrame:ToScaleSize()
	-- sets the frame's size using scale (relative to inventorywindow), used when the frame is snapped into the grid
	-- so it scales right if player somehow resizes the game window during play
	local X = self.GridSize.X
	local Y = self.GridSize.Y
	self.Instance.Size = UDim2.fromScale(
		GridSizeScaleX*X, GridSizeScaleY*Y
	)
end

function ItemFrame:ToAbsoluteScaleSize()
	-- set the frame's scale size (relative to the screen top left), used while the frame is attached to the cursor
	-- since the frame is parented under the screengui, basewindow relative scale would be wrong
	local X = self.GridSize.X
	local Y = self.GridSize.Y
	self.Instance.Size = UDim2.fromScale(
		AbsoluteGridXScale*X, AbsoluteGridYScale*Y
	)
end

function ItemFrame:AttachToCursor()
	-- bind the frame position (in offset) to the cursor every frame (PreRender/RenderStepped) in the center
	-- offset bc the pos is updated every frame anyway
	local AbsSize = self.Instance.AbsoluteSize
	local Connection

	Connection = RunService.PreRender:Connect(function()
		local MousePos = UIS:GetMouseLocation()
		-- subtract half of the frame absolute size from mousepos to center the frame 
		-- without this the frame would be attached to the cursor at the frame's top left corner
		self.Instance.Position = UDim2.fromOffset(MousePos.X - AbsSize.X/2, MousePos.Y - AbsSize.Y/2)
	end)
	return Connection
end

function ItemFrame:ParentToBase()
	-- parent the frame to the inventory window/base window for (easier calculation of) placement
	self.Instance.Parent = BaseWindow
end

function ItemFrame:Destroy()
	-- this just destroys the frame instance, to destroy the itemframe object we gotta set its UID key in table FrameObjects to nil
	-- which is done in InvUiModule:DiscardItem
	self.Instance:Destroy()
end

-- ui module, handles the ui visual grid inventory stuff (placement, using, equipping, discarding, checking info) while also acting as a limiter
-- singleton since each player only has one inventory and therefore one ui module for it
local InvUiModule = {
	Cooldown = false -- to prevent spamming and therefore bugs with setting the occupants in the gridspace table
}

function InvUiModule:Init(Main)
	-- main is the inventory module containing both this module and the logic module that handles storing and interacting with the actual items
	-- the items in the logic module share a unique id with their own frame object stored in FrameObjects
	self.Main = Main
	-- initialize the gridspace that allows for reliable grid placement of item frames
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

function InvUiModule.NewFrame(...)
	return ItemFrame.NewFrame(...)
end

function InvUiModule:ClickMoveFrame(ActionName, InputState)
	-- checks for item frame at mouse and start moving it on click
	if InputState ~= Enum.UserInputState.End then return Enum.ContextActionResult.Pass end
	
	self:HideActionPanel()
	local ItemAtMouse = GetInventoryItemAtMouse()
	if not ItemAtMouse then return Enum.ContextActionResult.Pass end
	
	local FrameObj = GetObjFromInstance(ItemAtMouse)
	self:StartMoveFrame(FrameObj, self.Main.Logic:GetItemByUID(FrameObj.UID))
	return Enum.ContextActionResult.Sink
end

function InvUiModule:ClickShowActionPanel(ActionName, InputState)
	-- checks for item frame at mouse and the action panel for interactions with that item
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

function InvUiModule:ShowActionPanel(FrameObj)
	-- shows the action panel on right click, allowing for item interactions such as use, equip and discard 
	local Position = PositionRelativeToWindow(GetMousePosition()) / BaseWindow.AbsoluteSize
	-- return the mouse position, in scale relative to the base window
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
	-- given an item object (the item data stored in the logic module), show the info panel (at the bottom left corner) displaying info
	-- of that item, specifically name, desc and its model rotating in a viewportframe
	-- boolean "show" is for toggling the info panel on or off
	if Obliterator:Get("CloseInfoCon") then
		Obliterator:Remove("CloseInfoCon")
	end
	
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
	-- since we have to loop to continuously add an y angle to the model so it rotates infinitely, we spawn a coroutine/task whatever
	-- to do the thing in the background
	task.spawn(RotateYTool, Model)
end

function InvUiModule:HideActionPanel()
	ActionPanel.Visible = false
	-- calls janitor to cleanup action buttons connections
	Obliterator:RemoveList("InfoCon", "DiscardCon", "UseCon")
end

function InvUiModule:NewItemEntry(FrameObj)
	-- since UID is "universally unique" (HttpService:GenerateGUID()), suitable for item dupes
	FrameObjects[FrameObj.UID] = FrameObj
end

function InvUiModule:DiscardItem(FrameObj)
	-- given a frame obj, delete its ui component and then its item data in the inventory logic module
	-- if the info panel is currently showing this item then hide the panel
	if CurrentInfoItem == FrameObj.UID then
		self:ShowInfoPanel(nil, false)
	end
	-- empty the area of the item frame to be discarded
	SetOccupantsInArea(FrameObj.CurrentGridPos, FrameObj.GridSize, nil)
	self.Main.Logic:DiscardItem(FrameObj.UID)
	
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
	
	-- attach item frame to cursor every frame (RunService.PreRender)
	-- and empty its old area in the gridspace
	-- bind placing the frame to left click at higher priority and sink to avoid picking it up again (ClickStartMoveFrame)
	
	FrameObj.Instance.ZIndex += 1  
	FrameObj.Instance.Parent = InventoryUi
	FrameObj:ToAbsoluteScaleSize()
	
	local PosUpdateConn : RBXScriptConnection = FrameObj:AttachToCursor()
	-- bool RepositionFrameUnder is to clarify whether we're moving/repositioning the frame that was just under the current item frame
	-- so we dont accidentally make that area occupied by the current item frame empty in gridspace
	-- otherwise, for bigger items like sword (2x5), when we reposition it after placing down hyperlaser (3x3)
	-- we accidentally mark some grids in the hyperlaser frame as empty creating an empty hole (according to gridspace)
	-- and inadvertently allowing for the placement of like 2 sodas (1x2) on top of the hyperlaser gun
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
