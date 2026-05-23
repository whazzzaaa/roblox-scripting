-- connected discord-github
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- modules
local GridModule = require(script.ModuleScript)
local JanitorService = require(ReplicatedStorage:WaitForChild("Janitor"))
-- ui
local Player = Players.LocalPlayer
local PlayerGui : BasePlayerGui = Player:WaitForChild("PlayerGui")
local InventoryUi : ScreenGui = PlayerGui:WaitForChild("InventoryUi")
local InfoPanel : Frame = InventoryUi:WaitForChild("Info")
local BaseWindow : Frame = InventoryUi:WaitForChild("Base")
local ActionPanel : Frame = BaseWindow:WaitForChild("ActionPanel")
local MarkTemp = BaseWindow:WaitForChild("markTemp")
-- constants
local GridSizeScaleX = 0.04545
local GridSizeScaleY = 0.2
local WindowWidth = 0.574   -- 704 in pixels
local WindowHeight = 0.21   -- 160 in pixels
local ItemTag = "InventoryGridItemFrame"
-- variables
local CurrentInfoItem
-- grid table
local Gridspace = {}
-- obj table
local FrameObjects = {}
-- obliterator
local Obliterator = JanitorService.new()
-- info tool cam
local InfoToolCam = Instance.new("Camera")
InfoToolCam.Name = "InfoToolCam"
InfoToolCam.CFrame = CFrame.new(-10.623, 1.9, 9.565) * CFrame.Angles(0, -math.pi/2, 0)
-- helper functions
local function RotateYTool(Model)
	local Prime : BasePart = Model.PrimaryPart
	while Model do
		Model:PivotTo(Prime.CFrame * 
			CFrame.Angles(0, math.rad(5), 0)
		)
		task.wait(0.05)
	end
end

local function isInRange(x, m, n)
	return (x >= m and x <= n)
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
	local OriginalX = math.ceil(RelativePosition.X / GridAbsSize.X)
	local OriginalY = math.ceil(RelativePosition.Y / GridAbsSize.Y)
	local GridX = math.clamp(
		OriginalX,
		1,
		22
	)
	local GridY = math.clamp(
		OriginalY,
		1,
		5
	)
	return Vector2.new(GridX, GridY), Vector2.new(OriginalX, OriginalY)
end

local function GridToPosition(Grid : Vector2)
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
end

local function GetOccupantsInArea(GridPosition, SizeX, SizeY)
	local Occupants = {}
	for x = GridPosition.X, GridPosition.X + SizeX - 1, 1 do
		for y = GridPosition.Y, GridPosition.Y + SizeY - 1, 1 do
			if not Gridspace[x] or not Gridspace[x][y] then return nil end
			local CurrentOccupant = Gridspace[x][y].Occupant
			if CurrentOccupant ~= nil then
				table.insert(Occupants,
					{
						X = x,
						Y = y,
						Occupant = CurrentOccupant
					}
				)
			end
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
			if not (Gridspace[x] or not Gridspace[x][y]) then return end
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
end

-- module
local InvUiModule = {
	Backpack = {},
	SizeX = 22,
	SizeY = 5,
	MovingFrame = false,
	Cooldown = false
}

function InvUiModule:Init(Main)
	self.Main = Main
	-- init grid table
	for x = 1,22, 1 do
		Gridspace[x] = {}
		for y = 1,5, 1 do
			Gridspace[x][y] = {Occupant = nil, Mark = nil}
			-- occupant will be unique instance of the grid frame object
		end
	end
	
	UIS.InputEnded:Connect(function(InputObj)
		if self.MovingFrame == true then return end
		-- grab item or show action panel depending on mouse left or mouse right on that item frame
		if InputObj.UserInputType == Enum.UserInputType.MouseButton1 then
			self:HideActionPanel()
			local ItemAtMouse = GetInventoryItemAtMouse()
			if ItemAtMouse then
				local FrameObj = GetObjFromInstance(ItemAtMouse)
				self:StartMoveFrame(FrameObj, self.Main.Logic:GetItemByUID(FrameObj.UID))
			end
		elseif InputObj.UserInputType == Enum.UserInputType.MouseButton2 then
			-- action panel
			local ItemAtMouse = GetInventoryItemAtMouse()
			if ItemAtMouse then
				local FrameObj = GetObjFromInstance(ItemAtMouse)
				self:ShowActionPanel(FrameObj)
				return
			end
			self:HideActionPanel()
		end
	end)
	return self
end

function InvUiModule:ShowActionPanel(FrameObj)
	local Position = PositionRelativeToWindow(GetMousePosition()) / BaseWindow.AbsoluteSize
	ActionPanel.Visible = true
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
	local UseCon = Button.MouseButton1Down:Once(function()
		if Item:IsA("Weapon") then
			self.Main.Logic:EquipUID(FrameObj.UID)
		else
			Item:Use()
		end
	end)
	
	Obliterator:Add(UseCon, "Disconnect", "UseCon")	
	Obliterator:Add(InfoCon, "Disconnect", "InfoCon")
	Obliterator:Add(DiscardCon, "Disconnect", "DiscardCon")
end

function InvUiModule:ShowInfoPanel(Item, Show)
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
	
	InfoPanel.Close.MouseButton1Down:Once(function()
		self:ShowInfoPanel(_, false)
	end)
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

function InvUiModule:DiscardItem(FrameObj) --only works while its in the ui inventory for now
	if CurrentInfoItem == FrameObj.UID then
		self:ShowInfoPanel(_, false)
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
	local FrameInstance = FrameObj.Instance
	local GridPosition, OriginalGridPos = PositionToGrid(FrameInstance.AbsolutePosition)
	
	local OccupantsInArea = GetOccupantsInArea(GridPosition, FrameObj.GridSize.X, FrameObj.GridSize.Y)
	if not OccupantsInArea then return end
	
	local OccupantInstances = {}
	for _, Table in OccupantsInArea do
		if Table and Table.Occupant and not table.find(OccupantInstances, Table.Occupant) then
			table.insert(OccupantInstances, Table.Occupant)
		end
	end
	-- table OccupantInstances is used to get how many unique items take up each grid in the area the player is attempting to place the current item frame
	if #OccupantInstances > 0 then return false end
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
	
	return true
end

function InvUiModule:StartMoveFrame(FrameObj, NewItem)
	-- verify
	if self.Cooldown == true then return end
	-- set bool and attach frame
	self.MovingFrame = true
	
	FrameObj.Instance.ZIndex += 1
	FrameObj.Instance.Parent = InventoryUi
	FrameObj:ToAbsoluteScaleSize()
	local PosUpdateConn = FrameObj:AttachToCursor()
	SetOccupantsInArea(FrameObj.CurrentGridPos, FrameObj.GridSize, nil)
	
	CAS:BindAction("PlaceFrame", 
		function(_, State)
			if State ~= Enum.UserInputState.End then return end  -- prevent both left mouse up and down trigger
			local PlaceSuccess = self:PlaceFrame(FrameObj)
			if PlaceSuccess then
				FrameObj.Instance.ZIndex -= 1
				self.MovingFrame = false
				-- communicate with inventory to add this item
				self.Main.Logic:AddItem(NewItem, NewItem.UID)
				CAS:UnbindAction("PlaceFrame")
				PosUpdateConn:Disconnect()
				self:StartCooldown()
			end
		end
	, false, Enum.UserInputType.MouseButton1)
end
-- to prevent spamming and therefore bugs with setting the occupants in the gridspace table
function InvUiModule:StartCooldown()
	self.Cooldown = true
	task.delay(0.25, function()
		self.Cooldown = false
	end)
end

return InvUiModule
-- item frame object module
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Players = game:GetService("Players")

local ItemTag = "InventoryGridItemFrame"

local AbsoluteGridXScale = 0.0261
local AbsoluteGridYScale = 0.0399

local Player = Players.LocalPlayer
local PlayerGui : BasePlayerGui = Player:WaitForChild("PlayerGui")
local InventoryUi : ScreenGui = PlayerGui:WaitForChild("InventoryUi")
local BaseWindow : Frame = InventoryUi:WaitForChild("Base")

local GridSizeScaleX = 0.045
local GridSizeScaleY = 0.2

local function GetGridAbsSize()
	return Vector2.new(
		BaseWindow.AbsoluteSize.X * GridSizeScaleX,
		BaseWindow.AbsoluteSize.Y * GridSizeScaleY
	)
end

local ItemFrame = {}
ItemFrame.__index = ItemFrame

function ItemFrame.NewFrame(ItemData, Index, UID)
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
	NewItemFrame.Index = Index
	NewItemFrame.Instance = FrameInstance
	NewItemFrame.GridSize = Vector2.new(X, Y)
	NewItemFrame.AttachOffset = Vector2.new(FrameInstance.AbsoluteSize.X/2, FrameInstance.AbsoluteSize.Y/2) -- since pivot is top left and we need that for the grid stuff
	NewItemFrame.UID = UID
	
	return setmetatable(NewItemFrame, ItemFrame)
end

function ItemFrame:ToScaleSize() -- relative to base
	local X = self.GridSize.X
	local Y = self.GridSize.Y
	self.Instance.Size = UDim2.fromScale(
		0.04545*X, 0.2*Y
	)
end

function ItemFrame:ToAbsoluteScaleSize()  -- relative to screen
	local X = self.GridSize.X
	local Y = self.GridSize.Y
	self.Instance.Size = UDim2.fromScale(
		AbsoluteGridXScale*X, AbsoluteGridYScale*Y
	)
end

function ItemFrame:AttachToCursor()
	local AbsSize = self.Instance.AbsoluteSize
	local Connection
	
	-- update pos every frame
	Connection = RunService.PreRender:Connect(function()
		local MousePos = UIS:GetMouseLocation()
		local Offset = self.AttachOffset
		self.Instance.Position = UDim2.fromOffset(MousePos.X - AbsSize.X/2, MousePos.Y - AbsSize.Y/2)
	end)
	return Connection
end

function ItemFrame:ParentToBase()
	self.Instance.Parent = BaseWindow
end

function ItemFrame:Destroy()
	self.Instance:Destroy()
	self = nil
end

return ItemFrame
