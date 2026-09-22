--!strict
-- GripSolver turns "where the weapon is" into joint angles. What matters is
-- that the angles it hands back really do put the weapon there: these solve a
-- grip, then walk the arm forward from the angles and check where the fist
-- and the weapon ended up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GripSolver = require(Shared.GripSolver)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

local function unit(v: { number }): { number }
	local l = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)
	return { v[1] / l, v[2] / l, v[3] / l }
end

local function merge(a: any, b: any): any
	local out = table.clone(a)
	for k, v in b do
		out[k] = v
	end
	return out
end

-- Grips across the space in front of and around the body, all within reach.
local GRIPS = {
	{ at = { 0.6, 0.2, -1.6 }, point = { 0, 0.3, -1 } },
	{ at = { 1.2, 1.4, -0.4 }, point = { 0.2, 0.6, 1 } },
	{ at = { 0.1, -0.3, -1.4 }, point = { -1, 0, -0.4 } },
	{ at = { 1.6, -0.9, -0.6 }, point = { 0, 1, 0 } },
	{ at = { 0.3, 1.9, -0.5 }, point = { 0, -0.2, 1 } },
	{ at = { 1.9, 0.4, 0.2 }, point = { 1, 0, 0.3 } },
}

describe("GripSolver.hold", function()
	it("puts the fist where it was asked, pointing the way it was asked", function()
		for index, spec in GRIPS do
			local poses, shortfall = GripSolver.hold("Right", spec :: any)
			check(`grip {index} reached`, shortfall < 1e-6)

			local grip = GripSolver.gripFrame(poses, "Right")
			check(`grip {index} position`, GripSolver.distance(grip, spec.at) < 1e-3)

			local pointing = GripSolver.pointing(poses, "Right")
			check(`grip {index} direction`, GripSolver.distance(pointing, unit(spec.point)) < 1e-3)
		end
	end)

	it("only ever bends the elbow the way an elbow bends", function()
		for index, spec in GRIPS do
			local poses = GripSolver.hold("Right", spec :: any)
			local elbow = poses.RightLowerArm.rx :: number
			check(`grip {index} elbow {elbow}`, elbow >= 0 and elbow <= 180)
		end
	end)

	it("reports a grip out of reach instead of pretending", function()
		local _, shortfall = GripSolver.hold("Right", { at = { 0, 0, -8 }, point = { 0, 0, -1 } })
		check("shortfall reported", shortfall > 3)
	end)
end)

describe("GripSolver.offHand", function()
	it("puts the other hand on the haft, the same way round", function()
		for index, spec in GRIPS do
			local right = GripSolver.hold("Right", spec :: any)
			local left, shortfall = GripSolver.offHand(right, "Right", -1.2)
			if shortfall > 0 then
				continue
			end
			local poses = merge(right, left)

			local rightGrip = GripSolver.gripFrame(poses, "Right")
			local leftGrip = GripSolver.gripFrame(poses, "Left")
			local dir = GripSolver.pointing(poses, "Right")
			local expected = { rightGrip[1] - dir[1] * 1.2, rightGrip[2] - dir[2] * 1.2, rightGrip[3] - dir[3] * 1.2 }
			check(`grip {index} off hand on the haft`, GripSolver.distance(leftGrip, expected) < 1e-3)
			check(`grip {index} same way round`, GripSolver.distance(GripSolver.pointing(poses, "Left"), dir) < 1e-3)
		end
	end)
end)

describe("GripSolver.aim", function()
	it("turns only the wrist, and points the weapon where asked", function()
		local arm = { RightUpperArm = { rx = 70, rz = 20 }, RightLowerArm = { rx = 30 } }
		for _, point in { { 0, 0, -1 }, { -1, 0.2, -0.5 }, { 0.3, 1, 0.4 } } do
			local wrist = GripSolver.aim(arm :: any, "Right", point)
			local poses = merge(arm, { RightHand = wrist })
			check("points", GripSolver.distance(GripSolver.pointing(poses, "Right"), unit(point)) < 1e-3)
		end
	end)
end)

describe("GripSolver angles", function()
	it("reads a rotation back as the same rotation", function()
		for _, angles in { { 10, 20, 30 }, { 170, -60, 95 }, { -45, 89.9, 12 }, { 0, -90, 40 } } do
			local read = GripSolver.toAngles(angles[1], angles[2], angles[3])
			local original = { rx = angles[1], ry = angles[2], rz = angles[3] }
			check(`{angles[1]},{angles[2]},{angles[3]}`, GripSolver.sameRotation(read, original) < 1e-6)
		end
	end)
end)
