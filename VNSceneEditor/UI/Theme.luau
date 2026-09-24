-- Single place to retune the editor's look.

local Theme = {}

Theme.Backdrop = Color3.fromRGB(14, 14, 22)
Theme.Panel = Color3.fromRGB(24, 25, 36)
Theme.PanelAlt = Color3.fromRGB(32, 34, 48)
Theme.Row = Color3.fromRGB(38, 40, 56)
Theme.RowHover = Color3.fromRGB(48, 51, 70)
Theme.Input = Color3.fromRGB(18, 19, 28)
Theme.Border = Color3.fromRGB(58, 61, 84)

Theme.Text = Color3.fromRGB(234, 236, 244)
Theme.TextDim = Color3.fromRGB(154, 158, 180)
Theme.TextFaint = Color3.fromRGB(104, 108, 128)

Theme.Accent = Color3.fromRGB(255, 59, 127)
Theme.Button = Color3.fromRGB(46, 49, 68)
Theme.Good = Color3.fromRGB(58, 176, 118)
Theme.Danger = Color3.fromRGB(206, 66, 74)

-- Timed segments and dialogue blocks must read as different things at a glance.
Theme.Timed = Color3.fromRGB(52, 116, 208)
Theme.TimedSoft = Color3.fromRGB(30, 48, 78)
Theme.Dialogue = Color3.fromRGB(190, 68, 168)
Theme.DialogueSoft = Color3.fromRGB(62, 32, 62)

Theme.Font = Enum.Font.Gotham
Theme.FontBold = Enum.Font.GothamBold
Theme.FontMono = Enum.Font.Code

Theme.PanelHeight = 0.44

return Theme
