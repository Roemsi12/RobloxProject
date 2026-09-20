--!strict
-- Plays the sounds named in SoundDefs: in the world at a position, so nearby
-- fights are louder than distant ones, or flat for things that happen to you.
--
-- Every sound is a fresh instance on this client only and cleans itself up.
-- Nothing replicates, and nothing here decides anything.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local SoundDefs = require(ReplicatedStorage.Shared.SoundDefs)

local SoundFX = {}

-- Heard at full volume within this distance, fading to silence at the max.
local ROLL_OFF_MIN = 12
local ROLL_OFF_MAX = 140

-- Longer than any clip, in case Ended never fires (a clip that fails to load).
local CLEANUP_AFTER = 8

local warned: { [string]: boolean } = {}

-- A sound definition by name, warning once if there is none. Once rather
-- than every time: a missing sound on a swing would otherwise fill the
-- output with the same line several times a second.
local function defFor(name: string): SoundDefs.SoundDef?
	local def = SoundDefs.get(name)
	if not def and not warned[name] then
		warned[name] = true
		warn(`[SoundFX] No sound named "{name}" in SoundDefs`)
	end
	return def
end

-- A Sound instance from a definition, with its pitch rolled inside the
-- definition's range so repeats never sound identical.
local function newSound(def: SoundDefs.SoundDef): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.PlaybackSpeed = SoundDefs.pitchFor(def, math.random())
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = ROLL_OFF_MIN
	sound.RollOffMaxDistance = ROLL_OFF_MAX
	return sound
end

-- Plays a sound and destroys its holder when it ends, so nothing
-- accumulates in Workspace over a long session.
local function playAndClean(sound: Sound, holder: Instance)
	sound.Ended:Once(function()
		holder:Destroy()
	end)
	task.delay(CLEANUP_AFTER, function()
		if holder.Parent then
			holder:Destroy()
		end
	end)
	sound:Play()
end

-- A sound for the local player alone, the same volume wherever they stand.
function SoundFX.play(name: string)
	local def = defFor(name)
	if not def then
		return
	end

	local sound = newSound(def)
	sound.Parent = SoundService
	playAndClean(sound, sound)
end

-- A sound coming from a point in the world.
function SoundFX.playAt(name: string, position: Vector3)
	local def = defFor(name)
	if not def then
		return
	end

	-- Terrain sits at the origin, so an attachment's Position there is a world
	-- position.
	local holder = Instance.new("Attachment")
	holder.Name = "SoundFX"
	holder.Position = position
	holder.Parent = Workspace.Terrain

	local sound = newSound(def)
	sound.Parent = holder
	playAndClean(sound, holder)
end

-- Preloads every clip in the background, so the first parry is not silent
-- while its sound is still downloading.
function SoundFX.start()
	-- Load every clip up front so the first parry isn't silent while its sound
	-- downloads. In the background: nothing waits on it.
	task.spawn(function()
		local seen: { [string]: boolean } = {}
		local sounds: { Instance } = {}
		for _, def in SoundDefs.SOUNDS do
			if not seen[def.id] then
				seen[def.id] = true
				local sound = Instance.new("Sound")
				sound.SoundId = def.id
				table.insert(sounds, sound)
			end
		end

		pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)
	end)
end

return SoundFX
