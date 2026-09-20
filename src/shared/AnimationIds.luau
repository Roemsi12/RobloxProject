--!strict
-- Published versions of the rough animations in AnimationDefs. Pure data.
--
-- Empty until an animation has been refined and published. Any animation
-- listed here plays through Roblox's own Animator instead of the rough
-- version, with no code change. To refine one:
--
--   1. `lune run animation-workbench`, and drag workbench/AnimationWorkbench.rbxm
--      into a Studio place.
--   2. Select a rig, open the Animation Editor, and load the animation from
--      its saves (e.g. "attack_Slash").
--   3. Refine it. Attacks and swings: keep a keyframe named "Impact" at the
--      moment the hit lands — the game uses it to time the strike to the
--      server.
--   4. Publish it, and paste the ID under the rig and animation name:
--        SkeletonWarrior = { attack_Slash = "rbxassetid://1234567890" },
--
-- A published animation only plays in a live game if it belongs to the same
-- owner (you, or the group) as the experience.

local AnimationIds = {}

-- rigId -> animation name -> "rbxassetid://..."
AnimationIds.PUBLISHED = {
	TrainingDummy = {},
	SkeletonWarrior = {},
	Shambler = {},
	Spitter = {},
	R15Player = {},
} :: { [string]: { [string]: string } }

-- The published asset id for an animation, or nil if it has not been
-- refined yet — in which case the rough version in AnimationDefs plays.
-- An empty string counts as nil, so a half-filled row is not a broken id.
function AnimationIds.get(rigId: string, name: string): string?
	local rig = AnimationIds.PUBLISHED[rigId]
	local id = rig and rig[name]
	return if typeof(id) == "string" and id ~= "" then id else nil
end

return AnimationIds
