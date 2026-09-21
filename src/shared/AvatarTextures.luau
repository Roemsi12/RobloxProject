--!strict
-- The uploaded image id of every avatar texture, by the name of its file in
-- art/avatar/textures. Written by lune/upload-avatar.luau; edit by hand only to
-- point a name at a different image.
--
-- 0 means "not uploaded yet". AppearanceService skips a layer whose id is 0,
-- so a missing texture costs that layer of the look and nothing else.

return {
	shirt_ragged = 87448658774569,
	shirt_tunic = 89264200606237,
	shirt_leathers = 70946662906992,
	shirt_plate = 137245994241316,
	shirt_robes = 137098709472435,
	shirt_tabard = 101643743915751,
	shirt_wrappings = 83057154082234,
	shirt_cloak = 116064609415219,

	pants_trousers = 125480815129176,
	pants_ragged = 121048955829128,
	pants_greaves = 132090075267173,
	pants_robe = 129499805067616,
	pants_wraps = 120093042669622,

	overlay_ragged = 133190348426947,
	overlay_tunic = 116447232891250,
	overlay_leathers = 74046390856173,
	overlay_plate = 126397603893863,
	overlay_robes = 80510806863668,
	overlay_tabard = 124364375326751,
	overlay_wrappings = 107128416691828,
	overlay_cloak = 118142423035818,

	face_steady = 80616687860066,
	face_grim = 70631310118228,
	face_weary = 70646980931838,
	face_fierce = 114767534510259,
	face_calm = 92926807755208,
	face_hollow = 103483204649079,
	face_mask = 110430053986745,

	eyes_natural = 97092882984841,
	eyes_narrow = 117790690743881,
	eyes_glow = 139671319474909,
	eyes_sockets = 129603341213232,
	eyes_slits = 112420419081609,

	mark_warpaint = 139630950101565,
	mark_scar = 102520002106791,
	mark_brand = 95838627844033,
	mark_ash = 102220853931478,
	mark_tattoo = 88614923943132,
	mark_stitched = 130913422290608,
} :: { [string]: number }
