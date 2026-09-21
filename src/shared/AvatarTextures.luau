--!strict
-- The uploaded image id of every avatar texture, by the name of its file in
-- art/avatar/textures. Written by art/avatar/upload.py; edit by hand only to
-- point a name at a different image.
--
-- 0 means "not uploaded yet". AppearanceService skips a layer whose id is 0,
-- so a missing texture costs that layer of the look and nothing else.

return {
	shirt_ragged = 0,
	shirt_tunic = 0,
	shirt_leathers = 0,
	shirt_plate = 0,
	shirt_robes = 0,
	shirt_tabard = 0,
	shirt_wrappings = 0,
	shirt_cloak = 0,

	pants_trousers = 0,
	pants_ragged = 0,
	pants_greaves = 0,
	pants_robe = 0,
	pants_wraps = 0,

	overlay_ragged = 0,
	overlay_tunic = 0,
	overlay_leathers = 0,
	overlay_plate = 0,
	overlay_robes = 0,
	overlay_tabard = 0,
	overlay_wrappings = 0,
	overlay_cloak = 0,

	face_steady = 0,
	face_grim = 0,
	face_weary = 0,
	face_fierce = 0,
	face_calm = 0,
	face_hollow = 0,
	face_mask = 0,

	eyes_natural = 0,
	eyes_narrow = 0,
	eyes_glow = 0,
	eyes_sockets = 0,
	eyes_slits = 0,

	mark_warpaint = 0,
	mark_scar = 0,
	mark_brand = 0,
	mark_ash = 0,
	mark_tattoo = 0,
	mark_stitched = 0,
} :: { [string]: number }
