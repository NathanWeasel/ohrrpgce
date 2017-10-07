'The OHRRPGCE graphics, audio and user input library!
'Please read LICENSE.txt for GNU GPL license details and disclaimer of liability
'
'This module is completely bool-clean (bool always used when appropriate)

#include "config.bi"
#include "crt/limits.bi"
#include "string.bi"
#include "common.bi"
#include "allmodex.bi"
#include "gfx.bi"
#include "surface.bi"
#include "music.bi"
#include "reload.bi"
#include "util.bi"
#include "const.bi"
#include "uiconst.bi"
#include "slices.bi"
#include "loading.bi"

using Reload

#ifdef IS_GAME
 #include "game.bi"  'For exit_gracefully
#endif

#ifdef __FB_ANDROID__
'This is gfx_sdl specific, of course, but a lot of the stuff in our fork of the android fork
'of SDL 1.2 would more make sense to live in totally separate java files, which is something we will
'want to do to support SDL 2 on Android.
extern "C"
	'Return value is always 1
	declare function SDL_ANDROID_EmailFiles(address as zstring ptr, subject as zstring ptr, message as zstring ptr, file1 as zstring ptr = NULL, file2 as zstring ptr = NULL, file3 as zstring ptr = NULL) as integer
end extern
#endif


'Note: While non-refcounted frames work (at last check), it's not used anywhere, and you most probably do not need it
'NOREFC is also used to indicate uncached Palette16's. Note Palette16's are NOT refcounted in the way as frames
const NOREFC = -1234
const FREEDREFC = -4321

type XYPair_node 	'only used for floodfill
	x as integer
	y as integer
	nextnode as XYPair_node ptr
end type


'----------- Local functions ----------

declare function frame_load_uncached(sprtype as SpriteType, record as integer) as Frame ptr
declare sub _frame_copyctor cdecl(dest as frame ptr ptr, src as frame ptr ptr)

declare sub frame_draw_internal(src as Frame ptr, masterpal() as RGBcolor, pal as Palette16 ptr = NULL, x as integer, y as integer, scale as integer = 1, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
declare sub draw_clipped(src as Frame ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
declare sub draw_clipped_scaled(src as Frame ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, scale as integer, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
declare sub draw_clipped_surf(src as Surface ptr, master_pal as RGBPalette ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, trans as bool, dest as Surface ptr)

'declare sub grabrect(byval page as integer, byval x as integer, byval y as integer, byval w as integer, byval h as integer, ibuf as ubyte ptr, tbuf as ubyte ptr = 0)
declare function write_bmp_header(filen as string, w as integer, h as integer, bitdepth as integer) as integer
declare function decode_bmp_bitmask(mask as uint32) as integer
declare sub loadbmp32(byval bf as integer, byval surf as Surface ptr, infohd as BITMAPV3INFOHEADER)
declare sub loadbmp24(byval bf as integer, byval surf as Surface ptr)
declare sub loadbmp8(byval bf as integer, byval fr as Frame ptr)
declare sub loadbmp4(byval bf as integer, byval fr as Frame ptr)
declare sub loadbmp1(byval bf as integer, byval fr as Frame ptr)
declare sub loadbmprle8(byval bf as integer, byval fr as Frame ptr)
declare sub loadbmprle4(byval bf as integer, byval fr as Frame ptr)

declare sub stop_recording_gif()
declare sub gif_record_frame(fr as Frame ptr, palette() as RGBcolor)

declare function next_unused_screenshot_filename() as string
declare sub snapshot_check()

declare function calcblock(tmap as TileMap, byval x as integer, byval y as integer, byval overheadmode as integer, pmapptr as TileMap ptr) as integer

declare sub screen_size_update ()

declare sub pollingthread(byval as any ptr)
declare function read_inputtext () as string
declare sub update_mouse_state ()
declare sub check_for_released_mouse_button(byval buttonnum as MouseButton)

declare sub load_replay_header ()
declare sub record_input_tick ()
declare sub replay_input_tick ()
declare sub read_replay_length ()

declare function draw_allmodex_recordable_overlays (page as integer) as bool
declare function draw_allmodex_overlays (page as integer) as bool
declare sub show_replay_overlay()
declare sub hide_overlays ()
declare sub update_fps_counter (skipped as bool)
declare sub allmodex_controls ()
declare sub replay_controls ()

declare function time_draw_calls_from_finish() as bool

declare function hexptr(p as any ptr) as string

declare sub Palette16_delete(byval f as Palette16 ptr ptr)


#define POINT_CLIPPED(x, y) ((x) < clipl orelse (x) > clipr orelse (y) < clipt orelse (y) > clipb)

#define PAGEPIXEL(x, y, p) vpages(p)->image[vpages(p)->pitch * (y) + (x)]
#define FRAMEPIXEL(x, y, fr) fr->image[fr->pitch * (y) + (x)]

' In a function, pass return value on error
#macro CHECK_FRAME_8BIT(fr, what...)
	if (fr)->image = NULL then
		' Probably usually indicates that the Frame is Surface-backed
		debug __FUNCTION__ & ": NULL Frame.image"
		return what  'If what isn't given, just "return"
	end if
#endmacro

'------------ Global variables ------------

dim modex_initialised as bool = NO
dim vpages() as Frame ptr
dim vpagesp as Frame ptr ptr  'points to vpages(0) for debugging: fbc outputs typeless debugging symbol
dim default_page_bitdepth as integer = 8  '8 or 32. Affects allocatepage only, set by switch_to_*bit_vpages()

'Whether the player has at any point toggled fullscreen/windowed in some low-level way
'like alt+enter or window buttons.
dim user_toggled_fullscreen as bool = NO

redim fonts(3) as Font ptr

'Toggles 0-1 every time dowait is called
dim global_tog as integer

'Convert scancodes to text; Enter does not insert newline!
'This array is a global instead of an internal detail because it's used by charpicker and the font editor
'to work out key mapping for the extended characters. Would be nice if it weren't needed.
'FIXME: discover why this array is filled with empty values on Android
'key2text(0,*): no modifiers
'key2text(1,*): shift
'key2text(2,*): alt
'key2text(3,*): alt+shift
dim key2text(3,53) as string*1 => { _
	{"", "", "1","2","3","4","5","6","7","8","9","0","-","=","","","q","w","e","r","t","y","u","i","o","p","[","]","","","a","s","d","f","g","h","j","k","l",";","'","`","","\","z","x","c","v","b","n","m",",",".","/"}, _
	{"", "", "!","@","#","$","%","^","&","*","(",")","_","+","","","Q","W","E","R","T","Y","U","I","O","P","{","}","","","A","S","D","F","G","H","J","K","L",":","""","~","","|","Z","X","C","V","B","N","M","<",">","?"}, _
	{"", "", !"\130",!"\131",!"\132",!"\133",!"\134",!"\135",!"\136",!"\137",!"\138",!"\139",!"\140",!"\141","","",!"\142",!"\143",!"\144",!"\145",!"\146",!"\147",!"\148",!"\149",!"\150",!"\151",!"\152",!"\153","","",!"\154",!"\155",!"\156",!"\157",!"\158",!"\159",!"\160",!"\161",!"\162",!"\163",!"\164",!"\165","",!"\166",!"\167",!"\168",!"\169",!"\170",!"\171",!"\172",!"\173",!"\174",!"\175",!"\176"}, _
	{"", "", !"\177",!"\178",!"\179",!"\180",!"\181",!"\182",!"\183",!"\184",!"\185",!"\186",!"\187",!"\188","","",!"\189",!"\190",!"\191",!"\192",!"\193",!"\194",!"\195",!"\196",!"\197",!"\198",!"\199",!"\200","","",!"\201",!"\202",!"\203",!"\204",!"\205",!"\206",!"\207",!"\208",!"\209",!"\210",!"\211",!"\212","",!"\213",!"\214",!"\215",!"\216",!"\217",!"\218",!"\219",!"\220",!"\221",!"\222",!"\223"} _
}
' Translate scancodes scNumpadSlash and up to ASCII.
' Again, Enter is skipped.
' *, -, + are missing, since their scancodes aren't contiguous with the others.
dim shared numpad2text(...) as string*1 => {"7","8","9","","4","5","6","","1","2","3","0","."}

' Frame type table
DEFINE_VECTOR_OF_TYPE_COMMON(Frame ptr, Frame_ptr, @_frame_copyctor, @frame_unload)


'--------- Module shared variables ---------

'For each vpage() element, this records whether it shouldn't be resized when the window size changes (normally is)
'(Not fully implemented, as it seems it would only benefit textbox_appearance_editor)
'dim shared fixedsize_vpages() as bool
dim shared clippedframe as Frame ptr  'used to track which Frame the clips are set for.
dim shared as integer clipl, clipt, clipr, clipb 'drawable area on clippedframe; right, bottom margins are excluded

'The current internal size of the window (takes effect at next setvispage).
'Should only be modified via set_resolution and unlock_resolution
dim shared windowsize as XYPair = (320, 200)
'Minimum window size; can't resize width or height below this. Default to (0,0): no bound
dim shared minwinsize as XYPair
dim shared resizing_enabled as bool = NO  'keeps track of backend state

dim shared bordertile as integer

'Tileset animation states
dim shared anim1 as integer
dim shared anim2 as integer

type SkippedFrame
	page as integer = -1

	declare sub drop()
	declare sub show()
end type

dim shared waittime as double
dim shared flagtime as double = 0.0
dim shared setwait_called as bool
dim shared tickcount as integer = 0
dim shared use_speed_control as bool = YES
dim shared ms_per_frame as integer = 55     'This is only used by the animation system, not the framerate control
dim shared requested_framerate as double    'Set by last setwait
dim shared base_fps_multiplier as double = 1.0 'Doesn't include effect of shift+tab
dim shared fps_multiplier as double = 1.0   'Effect speed multiplier, affects all setwait/dowaits
dim max_display_fps as integer = 90         'Skip frames if drawing more than this.
dim shared lastframe as double              'Time at which the last frame was displayed.
dim shared blocking_draws as bool = NO      'True if drawing the screen is a blocking call.
dim shared skipped_frame as SkippedFrame    'Records the last setvispage call if it was frameskipped.

dim shared last_setvispage as integer = -1  'Records the last setvispage. -1 if none.
                                            'Virtually always vpage; in fact using anything other than vpage
                                            'would cause a lot of functions like multichoice to glitch.
                                            'Don't use this directly; call getvispage instead!

#IFDEF __FB_DARWIN__
	' On OSX vsync will cause screen draws to block, so we shouldn't try to draw more than the refresh rate.
	' (Still doesn't work perfectly)
	max_display_fps = 60
	blocking_draws = YES
#ENDIF


type KeyboardState
	setkeys_elapsed_ms as integer       'Time since last setkeys call (used by keyval)
	keybd(scLAST) as integer            'keyval array
	key_down_ms(scLAST) as integer      'ms each key has been down
	diagonalhack as integer = -1        '-1 before call to keyval w/ arrow key, afterwards 0 or 2
	delayed_alt_keydown as bool = NO    'Whether have delayed reporting an ALT keypress
	keyrepeatwait as integer = 500
	keyrepeatrate as integer = 55
	inputtext as string
end type

dim shared real_kb as KeyboardState         'Always contains real keyboard state even if replaying
dim shared replay_kb as KeyboardState       'Contains replayed state of keyboard while replaying, else unused
dim shared last_setkeys_time as double      'Used to compute real_kb.setkeys_elapsed_ms
dim shared inputtext_enabled as bool = NO   'Whether to fetch real_kb.inputtext, not applied to replay_kb

#IFDEF __X11__
	'As a workaround for bug 2005, we disable native text input by default
	'on X11 (Linux/BSD). This can be removed when we figure out a better fix for that bug
	dim shared disable_native_text_input as bool = YES
#ELSE
	dim shared disable_native_text_input as bool = NO
#ENDIF

'Singleton type
type ReplayState
	active as bool             'Currently replaying input and not paused
	paused as bool             'While paused, keyval, etc, act on real_kb.
	filename as string         'Used only for error messages.
	file as integer = -1       'File handle
	tick as integer = -1       'Counts number of ticks we've replayed
	fpos as integer            'Debugging only: File offset of the tick chunk
	nexttick as integer = -1   'If we read the next tickcount from the file before it's needed
	                           'it's stored here. Otherwise -1.
	next_tick_ms as integer = 55 'Next tick milliseconds read before it's needed.
	debug as bool = NO         'Set to YES by editing this line; maybe add a commandline option
	length_ticks as integer    'Length in ticks (max tick num)
	length_ms as integer       'Approximate length of the replay, in milliseconds
	play_position_ms as integer 'Approximate position in replay in ms (calculated in same way as length_ms)
	repeat_count as integer    'Number of times to repeat the playback
	repeats_done as integer    'Number of repeats already finished.
end type

'Singleton type for recording input.
type RecordState
	file as integer = -1       'File handle
	active as bool             'Currently recording input and not paused.
	paused as bool             'While paused, calls to setkeys don't affect recording.
	tick as integer = -1       'Tick number, starting from zero.
	debug as bool = NO         'Set to YES by editing this line; maybe add a commandline option
	last_kb as KeyboardState   'Keyboard state during previous recorded tick
end type

dim shared replay as ReplayState
dim shared record as RecordState
dim shared macrofile as string

'Singleton type for recording a .gif.
type RecordGIFState
	'active as bool
	writer as GifWriter
	fname as string
	last_frame_end_time as double    'Nominal time when the delay for the last frame we wrote ends
	declare property active() as bool
	declare function delay() as integer
end type

dim shared recordgif as RecordGIFState
dim shared gif_max_fps as integer = 30
dim shared screenshot_record_overlays as bool = NO
dim shared gif_show_keys as bool         'While recording a gif, whether to display pressed keys
dim shared gif_show_mouse as bool        'While recording a gif, whether to display mouse location

dim shared closerequest as bool = NO     'It has been requested to close the program.

dim keybdmutex as any ptr                '(Global) Controls access to keybdstate(), mouseflags, mouselastflags, various backend functions,
                                         'and generally used to halt the polling thread.
dim shared keybdthread as any ptr        'id of the polling thread
dim shared endpollthread as bool         'signal the polling thread to quit
dim shared keybdstate(scLAST) as integer '"real"time keyboard array (only used internally by pollingthread)
dim shared mouseflags as integer
dim shared mouselastflags as integer
dim shared cursorvisibility as CursorVisibility = cursorDefault

'State of the mouse (set when setkeys is called), includes persistent state
dim shared mouse_state as MouseInfo
dim shared last_mouse_wheel as integer   'mouse_state.wheel at previous update_mouse_state call.

dim shared textfg as integer
dim shared textbg as integer

dim shared intpal(0 to 255) as RGBcolor	 'current palette
dim shared updatepal as bool             'setpal called, load new palette at next setvispage

dim shared fps_draw_frames as integer = 0 'Frames drawn since fps_time_start
dim shared fps_real_frames as integer = 0 'Frames sent to gfx backend since fps_time_start
dim shared fps_time_start as double = 0.0
dim shared draw_fps as double             'Current measured frame draw rate, per second
dim shared real_fps as double             'Current measured frame display rate, per second
dim shared overlay_showfps as integer = 0 'Draw on overlay? 0 (off), 1 (real fps), or 2 (draw fps)

dim shared overlays_enabled as bool = YES 'Whether to draw overlays in general
dim shared overlay_message as string      'Message to display on screen
dim shared overlay_hide_time as double    'Time at which to hide it
dim shared overlay_replay_display as bool

MAKETYPE_DoubleList(SpriteCacheEntry)
MAKETYPE_DListItem(SpriteCacheEntry)
'WARNING: don't add strings to this
type SpriteCacheEntry
	'cachelist used only if object is a member of sprcacheB
	cacheB as DListItem(SpriteCacheEntry)
	hashed as HashedItem
	p as frame ptr
	cost as integer
	Bcached as bool
end type

CONST SPRITE_CACHE_MULT = 1000000

dim shared sprcache as HashTable
dim shared sprcacheB as DoubleList(SpriteCacheEntry)
dim shared sprcacheB_used as integer    'number of slots full
'dim shared as integer cachehit, cachemiss

dim shared mouse_grab_requested as bool = NO
dim shared mouse_grab_overridden as bool = NO
dim shared remember_mouse_grab(3) as integer = {-1, -1, -1, -1}

dim shared remember_title as string       'The window title

dim shared global_sfx_volume as single = 1.



'==========================================================================================
'                                Initialisation and shutdown
'==========================================================================================


' Initialise anything in this module that's independent from the gfx backend
private sub modex_init()
	redim vpages(3)
	'redim fixedsize_vpages(3)  'Initially all NO
	vpagesp = @vpages(0)
	for i as integer = 0 to 3
		vpages(i) = frame_new(320, 200, , YES)
	next
	'other vpages slots are for temporary pages
	'They are currently still used in the tileset editor, importbmp, titlescreenbrowse,
	'and mapedit_linkdoors.
	'Except for the first two, they're assumed to be the same size as pages 0/1.

	clippedframe = NULL

	hash_construct(sprcache, offsetof(SpriteCacheEntry, hashed))
	dlist_construct(sprcacheB.generic, offsetof(SpriteCacheEntry, cacheB))
	sprcacheB_used = 0

	' TODO: tmpdir is shared by all instances of Custom, but when that is fixed this can be removed
	macrofile = tmpdir & "macro" & get_process_id() & ".ohrkeys"
end sub

' Initialise stuff specific to the backend (this is called after gfx_init())
private sub backend_init()
	'Polling thread variables
	endpollthread = NO
	mouselastflags = 0
	mouseflags = 0

	keybdmutex = mutexcreate
	if wantpollingthread then
		debuginfo "Starting IO polling thread"
		keybdthread = threadcreate(@pollingthread)
	end if

	io_init()
	'mouserect(-1,-1,-1,-1)

	fps_time_start = TIMER
	fps_draw_frames = 0
	fps_real_frames = 0

	if gfx_supports_variable_resolution() = NO then
		debuginfo "Resolution changing not supported"
		windowsize = XY(320, 200)
		'In case we're called from switch_gfx, resize video pages
		screen_size_update
	end if
end sub

' Initialise this module and backends, create a window
sub setmodex()
	modex_init()
	'Select and initialise a graphics/io backend
	init_preferred_gfx_backend()
	backend_init()

	modex_initialised = YES
end sub

' Cleans up anything in this module which is independent of the graphics backend
private sub modex_quit()
	stop_recording_input
	stop_recording_gif

	for i as integer = 0 to ubound(vpages)
		frame_unload(@vpages(i))
	next
	for i as integer = 0 to ubound(fonts)
		font_unload(@fonts(i))
	next

	hash_destruct(sprcache)
	'debug "cachehit = " & cachehit & " mis == " & cachemiss

	releasestack
	safekill macrofile
end sub

' Shuts down the gfx backend and cleans up everything that needs to be
private sub backend_quit()
	'clean up io stuff
	if keybdthread then
		endpollthread = YES
		threadwait keybdthread
		keybdthread = 0
	end if
	mutexdestroy keybdmutex

	skipped_frame.drop()

	gfx_close()
end sub

' Deinitialise this module and backends, destroy the window
sub restoremode()
	if modex_initialised = NO then exit sub
	modex_initialised = NO

	backend_quit
	modex_quit
end sub

' Switch to a different gfx backend
sub switch_gfx(backendname as string)
	debuginfo "switch_gfx " & backendname

	backend_quit()
	switch_gfx_backend(backendname)
	backend_init()

	' Re-apply settings (this is very incomplete)
	setwindowtitle remember_title
	io_setmousevisibility(cursorvisibility)
end sub

sub mersenne_twister (byval seed as double)
	if replay.active orelse replay.paused orelse record.active orelse record.paused then
		exit sub 'Seeding not allowed in play/record modes
	end if
	'FIXME: reseeding the RNG from scripts needs be allowed.
	'Either the seed should be recorded, or just don't allow any source of nondeterminism which could
	'be used as a seed (e.g. record results of all nondeterministic script commands).
	RANDOMIZE seed, 3
	debuginfo "mersenne_twister seed=" & seed
end sub

sub settemporarywindowtitle (title as string)
	'just like setwindowtitle but does not memorize the title
	mutexlock keybdmutex
	gfx_windowtitle(title)
	mutexunlock keybdmutex
end sub

sub setwindowtitle (title as string)
	remember_title = title
	mutexlock keybdmutex
	gfx_windowtitle(title)
	mutexunlock keybdmutex
end sub

function allmodex_setoption(opt as string, arg as string) as integer
	if opt = "no-native-kbd" then
		disable_native_text_input = YES
		debuginfo "Native text input disabled"
		return 1
	elseif opt = "native-kbd" then
		disable_native_text_input = NO
		debuginfo "Native text input enabled"
		return 1
	elseif opt = "runfast" then
		debuginfo "Running without speed control"
		enable_speed_control NO
		return 1
	elseif opt = "maxfps" then
		dim fps as integer = str2int(arg, -1)
		if fps > 0 then
			max_display_fps = fps
			return 2
		else
			display_help_string "--maxfps: invalid fps"
			return 1
		end if
	elseif opt = "giffps" then
		dim fps as integer = str2int(arg, -1)
		if fps > 0 then
			gif_max_fps = fps
			return 2
		else
			display_help_string "--giffps: invalid fps"
			return 1
		end if
	elseif opt = "recordoverlays" then
		screenshot_record_overlays = YES
		return 1
	elseif opt = "hideoverlays" then
		overlays_enabled = NO
		return 1
	elseif opt = "recordinput" then
		dim fname as string = absolute_with_orig_path(arg)
		if fileiswriteable(fname) then
			start_recording_input fname
			return 2 'arg used
		else
			display_help_string "input cannot be recorded to """ & fname & """ because the file is not writeable." & LINE_END
			return 1
		end if
	elseif opt = "replayinput" then
		dim fname as string = absolute_with_orig_path(arg)
		if fileisreadable(fname) then
			start_replaying_input fname
			return 2 'arg used
		else
			display_help_string "input cannot be replayed from """ & fname & """ because the file is not readable." & LINE_END
			return 1
		end if
	elseif opt = "showkeys" then
		gif_show_keys = YES
		return 1
	elseif opt = "showmouse" then
		gif_show_mouse = YES
		return 1
	end if
end function


'==========================================================================================
'                                        Video pages
'==========================================================================================


' Convert all videopages to 32 bit. Preserves their content
sub switch_to_32bit_vpages ()
	default_page_bitdepth = 32
	for i as integer = 0 to ubound(vpages)
		if vpages(i) then
			frame_convert_to_32bit vpages(i), intpal()
		end if
	next
end sub

' Convert all videopages to 8 bit Frames (not backed by Surfaces).
' WIPES their contents!
sub switch_to_8bit_vpages ()
	default_page_bitdepth = 8
	for i as integer = 0 to ubound(vpages)
		if vpages(i) then
			'frame_assign @vpages(i), frame_new(vpages(i)->w, vpages(i)->h)
			'Safer to use this, as it keeps extra state like .noresize
			frame_drop_surface vpages(i)
			clearpage i
		end if
	next
end sub

sub freepage (byval page as integer)
	if page < 0 orelse page > ubound(vpages) orelse vpages(page) = NULL then
		debug "Tried to free unallocated/invalid page " & page
		exit sub
	end if

	frame_unload(@vpages(page))
end sub

'Adds a Frame ptr to vpages(), returning its index.
function registerpage (byval spr as Frame ptr) as integer
	if spr->refcount <> NOREFC then	spr->refcount += 1
	for i as integer = 0 to ubound(vpages)
		if vpages(i) = NULL then
			vpages(i) = spr
			' Mark as fixed size, so it won't be resized when the window resizes.
			'fixedsize_vpages(i) = YES
			return i
		end if
	next

	redim preserve vpages(ubound(vpages) + 1)
	vpagesp = @vpages(0)
	vpages(ubound(vpages)) = spr
	'redim preserve fixedsize_vpages(ubound(vpages) + 1)
	'fixedsize_vpages(ubound(vpages)) = YES
	return ubound(vpages)
end function

'Create a new video page and return its index.
'bitdepth: 8 for a regular Frame, 32 for a 32-bit Surface-backed page, or -1 to use the default
'Note: the page is filled with color 0, unlike clearpage, which defaults to uiBackground!
function allocatepage(w as integer = -1, h as integer = -1, bitdepth as integer = -1) as integer
	if w < 0 then w = windowsize.w
	if h < 0 then h = windowsize.h
	if bitdepth < 0 then bitdepth = default_page_bitdepth
	if bitdepth <> 8 and bitdepth <> 32 then
		showerror "allocatepage: Bad bitdepth " & bitdepth
	end if
	dim fr as Frame ptr = frame_new(w, h, , YES, , bitdepth = 32)

	dim ret as integer = registerpage(fr)
	frame_unload(@fr) 'we're not hanging onto it, vpages() is

	return ret
end function

'creates a copy of a page, registering it (must be freed)
function duplicatepage (byval page as integer) as integer
	dim fr as Frame ptr = frame_duplicate(vpages(page))
	dim ret as integer = registerpage(fr)
	frame_unload(@fr) 'we're not hanging onto it, vpages() is
	return ret
end function

'Copy contents of one page onto another
'should copying to a page of different size resize that page?
sub copypage (byval src as integer, byval dest as integer)
	'if vpages(src)->w <> vpages(dest)->w or vpages(src)->h <> vpages(dest)->h then
	'	debug "warning, copied to page of unequal size"
	'end if
	frame_draw vpages(src), , 0, 0, , NO, vpages(dest)
end sub

sub clearpage (byval page as integer, byval colour as integer = -1)
	if colour = -1 then colour = uilook(uiBackground)
	frame_clear vpages(page), colour
end sub

'The contents are either trimmed or extended with colour uilook(uiBackground).
sub resizepage (page as integer, w as integer, h as integer)
	if vpages(page) = NULL then
		showerror "resizepage called with null ptr"
		exit sub
	end if
	frame_assign @vpages(page), frame_resized(vpages(page), w, h, 0, 0, uilook(uiBackground))
end sub

private function compatpage_internal(pageframe as Frame ptr) as Frame ptr
	return frame_new_view(vpages(vpage), (vpages(vpage)->w - 320) / 2, (vpages(vpage)->h - 200) / 2, 320, 200)
end function

'Return a video page which is a view on vpage hat is 320x200 (or smaller) and centred.
'In order to use this, draw to the returned page, but call setvispage(vpage).
'Do not swap dpage and vpage!
'WARNING: if a menu using compatpage calls another one that does swap dpage and
'vpage, things will break 50% of the time!
function compatpage() as integer
	dim fakepage as integer
	dim centreview as Frame ptr
	centreview = compatpage_internal(vpages(vpage))
	fakepage = registerpage(centreview)
	frame_unload @centreview
	return fakepage
end function


'==========================================================================================
'                                   Resolution changing
'==========================================================================================


'First check if the window was resized by the user,
'then if windowsize has changed (possibly by a call to unlock_resolution/set_resolution)
'resize all videopages (except compatpages) to the new window size.
'The videopages are either trimmed or extended with colour 0.
private sub screen_size_update ()
	'Changes windowsize if user tried to resize, otherwise does nothing
	if gfx_get_resize(windowsize) then
		'debuginfo "User window resize to " & windowsize.w & "*" & windowsize.h
		show_overlay_message windowsize.w & " x " & windowsize.h, 0.7
	end if

	'Clamping windowsize to the minwinsize here means trying to override user
	'resizes (specific to the case where the backend doesn't support giving the WM
	'a min size hint).
	'However unfortunately gfx_sdl can't reliably override it, at least with X11+KDE,
	'because the window size can't be changed while the user is still dragging the window
	'frame.
	'So just accept whatever the backend says the actual window size is.
	'windowsize.w = large(windowsize.w, minwinsize.w)
	'windowsize.h = large(windowsize.h, minwinsize.h)

	dim oldvpages(ubound(vpages)) as Frame ptr
	for page as integer = 0 to ubound(vpages)
		oldvpages(page) = vpages(page)
	next
	'oldvpages pointers will be invalidated

	'Resize dpage and vpage (I think it's better to hardcode 0 & 1 rather
	'than using dpage and vpage variables in case the later are temporarily changed)

	'Update size of all real pages. I think it's better to do so to all pages rather
	'than just page 0 and 1, as other pages are generally used as 'holdpages'.
	'The alternative is to update all menus using holdpages to clear the screen
	'before copying the holdpage over.
	'All pages which are not meant to be the same size as the screen
	'currently don't persist to the next frame.
	for page as integer = 0 to ubound(vpages)
		dim vp as Frame ptr = vpages(page)
		if vp andalso vp->isview = NO andalso vp->noresize = NO then
			if vp->w <> windowsize.w or vp->h <> windowsize.h then
				'debug "screen_size_update: resizing page " & page & " -> " & windowsize.w & "*" & windowsize.h
				resizepage page, windowsize.w, windowsize.h
			end if
		end if
	next

	'Scan for compatpages (we're assuming all views are compatpages, which isn't true in
	'general, but currently true when setvispage is called) and replace each with a new view
	'onto the center of the same page if it changed.
	for page as integer = 0 to ubound(vpages)
		if vpages(page) andalso vpages(page)->isview then
			for page2 as integer = 0 to ubound(oldvpages)
				if vpages(page)->base = oldvpages(page2) and vpages(page2) <> oldvpages(page2) then
					'debug "screen_size_update: updating view page " & page & " to new compatpage onto " & page2
					frame_unload @vpages(page)
					vpages(page) = compatpage_internal(vpages(page2))
					exit for
				end if
			next
			'If no match found, do nothing
		end if
	next

	'Update the size of the Screen slice.
	'This removes the need to call UpdateScreenSlice in all menus, but you can
	'still call it to find out if the size changed.
	UpdateScreenSlice NO  'clear_changed_flag=NO
end sub

'Set the size of a video page and keep it from being resized as the window size changes.
'TODO: delete this after the tile editor and importbmp stop using video pages 2 and 3
sub lock_page_size(page as integer, w as integer, h as integer)
	resizepage page, w, h
	vpages(page)->noresize = 1
end sub

'Revert a video page to following the size of the window
'TODO: delete this after the tile editor and importbmp stop using video pages 2 and 3
sub unlock_page_size(page as integer)
	resizepage page, windowsize.w, windowsize.h
	vpages(page)->noresize = 0
end sub

'Makes the window resizeable, and sets a minimum size.
'Whenever the window is resized all videopages (except compatpages) are resized to match.
sub unlock_resolution (byval min_w as integer, byval min_h as integer)
	minwinsize.w = min_w
	minwinsize.h = min_h
	if gfx_supports_variable_resolution() = NO then
		exit sub
	end if
	debuginfo "unlock_resolution(" & min_w & "," & min_h & ")"
	resizing_enabled = gfx_set_resizable(YES, minwinsize.w, minwinsize.h)
	windowsize.w = large(windowsize.w, minwinsize.w)
	windowsize.h = large(windowsize.h, minwinsize.h)
	screen_size_update  'Update page size
end sub

'Disable window resizing.
sub lock_resolution ()
	debuginfo "lock_resolution()"
	resizing_enabled = gfx_set_resizable(NO, 0, 0)
end sub

function resolution_unlocked () as bool
	return resizing_enabled
end function

'Set the window size, if possible, subject to min size bound. Doesn't modify resizability state.
'This will resize all videopages (except compatpages) to the new window size.
sub set_resolution (byval w as integer, byval h as integer)
	if gfx_supports_variable_resolution() = NO then
		exit sub
	end if
	debuginfo "set_resolution " & w & "*" & h
	windowsize.w = large(w, minwinsize.w)
	windowsize.h = large(h, minwinsize.h)
	'Update page size
	screen_size_update
	'Tell the gfx backend about the new page size. If we delayed this then a following
	'call to set_scale_factor would change scale and recenter window using wrong window size,
	'requiring manual recenter.
	'TODO: not ideal, should tell backend about size and scale at same time.
	setvispage vpage, NO
end sub

'The current internal window size in pixels (actual window updated at next setvispage)
function get_resolution() as XYPair
	return windowsize
end function

'Get resolution of the (primary) monitor. On Windows, this excludes size of the taskbar.
sub get_screen_size (byref screenwidth as integer, byref screenheight as integer)
	'Prefer os_get_screen_size because on windows it excludes the taskbar,
	'and gfx_sdl reports resolution at init time rather than the current values.
	os_get_screen_size(@screenwidth, @screenheight)
	if screenwidth <= 0 or screenheight <= 0 then
		debuginfo "Falling back to gfx_get_screen_size"
		gfx_get_screen_size(@screenwidth, @screenheight)
	end if
	debuginfo "Desktop resolution: " & screenwidth & "*" & screenheight
end sub

'Set the size that a pixel appears on the screen.
'Supported by all backends except gfx_alleg.
sub set_scale_factor (scale as integer)
	'gfx_sdl and gfx_fb, which use blit.c scaling, are limited to 1x-16x
	scale = bound(scale, 1, 16)
	debuginfo "Setting graphics scaling to x" & scale
	if gfx_setoption("zoom", str(scale)) = 0 then
		' Old versions of gfx_directx don't support zoom (TODO: delete this)
		gfx_setoption("width", str(windowsize.w * scale))
		gfx_setoption("height", str(windowsize.h * scale))
	end if
end sub

'Returns true if successfully queries the fullscreen state, in which case 'fullscreen' is set.
'(Note: gfx_fb doesn't know for certain whether it's fullscreen; can't catch alt+enter.
function try_check_fullscreen(byref fullscreen as bool) as bool
	dim winstate as WindowState ptr = gfx_getwindowstate()
	if winstate andalso winstate->structsize >= 4 then
		fullscreen = winstate->fullscreen
		return YES
	end if
	return NO
end function

function supports_fullscreen_well () as bool
	'Return YES if we should show the fullscreen/windowed menu options
	'and obey a game's fullscreen/windowed setting.
	'Note: even if this returns false, you can still try to fullscreen using alt-tab
	'or the --fullscreen arg and it might be supported.
	if running_on_desktop() = NO then
		return NO
	end if
#IFDEF __GNU_LINUX__
	' At least for me with KDE 4, fbgfx gives horrible results,
	' turning off my 2nd monitor and lots of garbage and desktop resolution changing,
	' and sometimes gets stuck with a fullscreen black screen.
	' SDL 1.2 does something milder (causing the 2nd monitor to switch to mirrored)
	' but only when the window size is smaller than the desktop.
	' So probably the solution in gfx_sdl is to set the requested resolution to
	' be equal to the desktop resolution and add black bars.
	if gfxbackend = "fb" then
		return NO
	end if
#ENDIF
	return YES
end function


'==========================================================================================
'                                   setvispage and Fading
'==========================================================================================

declare sub present_internal_frame(drawpage as integer)
declare sub present_internal_surface(drawpage as integer)

sub SkippedFrame.drop()
	'if page >= 0 then freepage page
	page = -1
end sub

' If the last setvispage was skipped, display it
sub SkippedFrame.show ()
	' Note: setvispage will call SkippedFrame.drop() after displaying the page
	if page > -1 then
		setvispage page, NO
	end if
end sub

' The last/currently displayed  videopage (or a substitute: guaranteed to be valid)
function getvispage() as integer
	if last_setvispage >= 0 andalso last_setvispage <= ubound(vpages) _
	   andalso vpages(last_setvispage) then
		return last_setvispage
	end if
	return vpage
end function

'Display a videopage. May modify the page!
'Also resizes all videopages to match the window size
'skippable: if true, allowed to frameskip this frame at high framerates
'preserve_page: if true, don't modify page
sub setvispage (page as integer, skippable as bool = YES, preserve_page as bool = NO)
	' Remember last page
	last_setvispage = page

	' Drop frames to reduce CPU usage if FPS too high
	if skippable andalso timer - lastframe < 1. / max_display_fps then
		skipped_frame.drop()
		skipped_frame.page = page
		' To be really cautious we could save a copy, but because page should
		' not get modified until it's time to draw the next frame, this isn't really needed.
		'skipped_frame.page = duplicatepage(page)
		update_fps_counter YES
		exit sub
	end if

	update_fps_counter NO
	if not time_draw_calls_from_finish then
		lastframe = timer
	end if

	dim starttime as double = timer
	if gfx_supports_variable_resolution() = NO then
		'Safety check. We must stick to 320x200, otherwise the backend could crash.
		'In future backends should be updated to accept other sizes even if they only support 320x200
		'(Actually gfx_directx appears to accept other sizes, but I can't test)
		if vpages(page)->w <> 320 or vpages(page)->h <> 200 then
			resizepage page, 320, 200
			showerror "setvispage: page was not 320x200 even though gfx backend forbade it"
		end if
	end if

	' The page to which to draw overlays, and display
	dim drawpage as integer = page
	if preserve_page then
		drawpage = duplicatepage(page)
	end if

	'Dray those overlays that are always recorded in .gifs/screenshots
	draw_allmodex_recordable_overlays drawpage

	if screenshot_record_overlays = YES then
		'Modifies page. This is bad if displaying a page other than vpage/dpage!
		draw_allmodex_overlays drawpage
	end if

	'F12 for screenshots handled here (uses real_keyval)
	snapshot_check
	gif_record_frame vpages(drawpage), intpal()

	if screenshot_record_overlays = NO then
		draw_allmodex_overlays drawpage
	end if

	'the fb backend may freeze up if it collides with the polling thread
	mutexlock keybdmutex

	starttime += timer  'Stop timer
	dim starttime2 as double = timer

	if vpages(page)->surf then
		present_internal_surface drawpage
	else
		present_internal_frame drawpage
	end if

	' This gets triggered a lot under Win XP because the program freezes while moving
	' the window (in all backends, although in gfx_fb it freezes readmouse instead)
	debug_if_slow(starttime2, 0.05, "gfx_present")
	starttime -= timer  'Restart timer

	mutexunlock keybdmutex

	if preserve_page then
		freepage drawpage
	end if

	if time_draw_calls_from_finish then
		' Have to give the backend and driver a millisecond or two to display the frame or we'll miss it
		lastframe = timer - 0.004
	end if

	skipped_frame.drop()  'Delay dropping old frame; skipped_frame.show() might have called us

	'After presenting the page this is a good time to check for window size changes and
	'resize the videopages as needed before the next frame is rendered.
	screen_size_update
	debug_if_slow(starttime, 0.05, "")
end sub

'setvispage internal function for presenting a regular Frame page on the screen
private sub present_internal_frame(drawpage as integer)
	' if updatepal then
	' 	gfx_setpal(@intpal(0))
	' 	updatepal = NO
	' end if
	' with *vpages(drawpage)
	' 	gfx_showpage(.image, .w, .h)
	' end with

	dim surf as Surface ptr
	if gfx_surfaceCreateFrameView(vpages(drawpage), @surf) then return

	dim surface_pal as RGBPalette ptr
	if surf->format = SF_8bit then
		' Need to provide a palette
		gfx_paletteFromRGB(@intpal(0), @surface_pal)
	end if

	gfx_present(surf, surface_pal)
	updatepal = NO  'We just did

	gfx_paletteDestroy(@surface_pal)
	gfx_surfaceDestroy(@surf)
end sub

'setvispage internal function for presenting a Surface-backed page on the screen
private sub present_internal_surface(drawpage as integer)
	dim drawsurf as Surface ptr = vpages(drawpage)->surf

	dim surface_pal as RGBPalette ptr
	if drawsurf->format = SF_8bit then
		' Need to provide a palette
		gfx_paletteFromRGB(@intpal(0), @surface_pal)
	end if

	gfx_present(drawsurf, surface_pal)
	updatepal = NO  'We just did

	gfx_paletteDestroy(@surface_pal)
end sub

' Change the palette at the NEXT setvispage call (or before next screen fade).
sub setpal(pal() as RGBcolor)
	memcpy(@intpal(0), @pal(0), 256 * SIZEOF(RGBcolor))

	updatepal = YES
end sub

' A gfx_setpal wrapper which may perform frameskipping to limit fps
private sub maybe_do_gfx_setpal()
	updatepal = YES
	if timer - lastframe < 1. / max_display_fps then
		update_fps_counter YES
		exit sub
	end if
	update_fps_counter NO
	if not time_draw_calls_from_finish then
		lastframe = timer
	end if

	mutexlock keybdmutex
	gfx_setpal(@intpal(0))
	mutexunlock keybdmutex

	updatepal = NO
	if time_draw_calls_from_finish then
		' Have to give the backend and driver a millisecond or two to display the frame or we'll miss it
		lastframe = timer - 0.004
	end if
end sub

sub fadeto (byval red as integer, byval green as integer, byval blue as integer)
	dim i as integer
	dim j as integer
	dim diff as integer

	skipped_frame.show()  'If we frame-skipped last frame, better show it

	if updatepal then
		maybe_do_gfx_setpal
		gif_record_frame vpages(getvispage()), intpal()
	end if

	for i = 1 to 32
		setwait 16.67 ' aim to complete fade in 550ms
		for j = 0 to 255
			'red
			diff = intpal(j).r - red
			if diff > 0 then
				intpal(j).r -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).r -= iif(diff <= -8, -8, diff)
			end if
			'green
			diff = intpal(j).g - green
			if diff > 0 then
				intpal(j).g -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).g -= iif(diff <= -8, -8, diff)
			end if
			'blue
			diff = intpal(j).b - blue
			if diff > 0 then
				intpal(j).b -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).b -= iif(diff <= -8, -8, diff)
			end if
		next
		maybe_do_gfx_setpal

		if i mod 3 = 0 then
			' We're assuming that the page hasn't been modified since the last setvispage
			gif_record_frame vpages(getvispage()), intpal()
		end if

		dowait
	next
	'Make sure the palette gets set on the final pass

	'This function was probably called in the middle of timed loop, call
	'setwait to avoid "dowait without setwait" warnings
	setwait 0
end sub

sub fadetopal (pal() as RGBcolor)
	dim i as integer
	dim j as integer
	dim diff as integer

	skipped_frame.show()  'If we frame-skipped last frame, better show it

	if updatepal then
		maybe_do_gfx_setpal
		gif_record_frame vpages(getvispage()), intpal()
	end if

	for i = 1 to 32
		setwait 16.67 ' aim to complete fade in 550ms
		for j = 0 to 255
			'red
			diff = intpal(j).r - pal(j).r
			if diff > 0 then
				intpal(j).r -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).r -= iif(diff <= -8, -8, diff)
			end if
			'green
			diff = intpal(j).g - pal(j).g
			if diff > 0 then
				intpal(j).g -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).g -= iif(diff <= -8, -8, diff)
			end if
			'blue
				diff = intpal(j).b - pal(j).b
			if diff > 0 then
				intpal(j).b -= iif(diff >= 8, 8, diff)
			elseif diff < 0 then
				intpal(j).b -= iif(diff <= -8, -8, diff)
			end if
		next

		if i mod 3 = 0 then
			' We're assuming that the page hasn't been modified since the last setvispage
			gif_record_frame vpages(getvispage()), intpal()
		end if

		maybe_do_gfx_setpal
		dowait
	next

	'This function was probably called in the middle of timed loop, call
	'setwait to avoid "dowait without setwait" warnings
	setwait 0
end sub


'==========================================================================================
'                                     Waits/Framerate
'==========================================================================================


sub enable_speed_control(byval setting as bool = YES)
	use_speed_control = setting
end sub

'Decides whether to time when to display the next frame (deciding whether to skip
'a frame or not) based on when the last gfx_showpage/gfx_present returned instead
'of when it was called.
'Normally we should just try to display a frame every refresh-interval, but on OSX
'presenting the window blocks until vsync, which means if we time from the call
'time rather than the return time, then we'll always be unnecessarily waiting
'even if speedcontrol is disabled. (If we're not trying to go fast then this waiting
'is OK, because it only happens if we displayed a frame earlier than necessary.)
'So this is only useful if we are frame skipping to run at more than the refresh rate!
private function time_draw_calls_from_finish() as bool
	if blocking_draws = NO then
		' Normally this is undesirable
		return NO
	else
		' Otherwise, only turn this on if we're trying to go FAST
		' (But allow for 16 ms = 62.5fps)
		return (use_speed_control = NO or requested_framerate > max_display_fps + 3)
	end if
end function

'Set number of milliseconds from now when the next call to dowait returns.
'This number is treated as a desired framewait, so actual target wait varies from 0.5-1.5x requested.
'ms:     number of milliseconds
'flagms: if nonzero, is a count in milliseconds for the secondary timer, whether this has triggered
'        is accessed as the return value from dowait.
sub setwait (byval ms as double, byval flagms as double = 0)
	if use_speed_control = NO then ms = 0.001
	ms /= fps_multiplier
	'flagms /= fps_multiplier
	requested_framerate = 1. / ms
	dim thetime as double = timer
	dim target as double = waittime + ms / 1000
	waittime = bound(target, thetime + 0.5 * ms / 1000, thetime + 1.5 * ms / 1000)
	if flagms <= 0 then
		flagms = ms
	end if
	if thetime > flagtime then
		flagtime = bound(flagtime + flagms / 1000, thetime + 0.0165, thetime + 1.5 * flagms / 1000)
	end if
	setwait_called = YES
end sub

' Returns number of dowait calls
function get_tickcount() as integer
	return tickcount
end function

function dowait () as bool
'wait until alarm time set in setwait()
'returns true if the flag time has passed (since the last time it was passed)
'In freebasic, sleep is in 1000ths, and a value of less than 100 will not
'be exited by a keypress, so sleep for 5ms until timer > waittime.
	tickcount += 1
	global_tog XOR= 1
	dim i as integer
	dim starttime as double = timer
	do while timer <= waittime - 0.0005
		i = bound((waittime - timer) * 1000, 1, 5)
		sleep i
		io_waitprocessing()
	loop
	' dowait might be called after waittime has already passed, ignore that
        ' (the time printed is the unwanted delay).
	' On Windows FB sleep calls winapi Sleep(), which has a default of 15.6ms, adjustable
	' with timeBeginPeriod(). 15.6ms is very coarse for 60fps games, so we probably
	' should request a higher frequency. (Also, Win XP rounds the sleep period up to the
	' following tick, while Win 7+ rounds it down, although that probably makes no
	' difference due to the avoid while loop. See
	' https://randomascii.wordpress.com/2013/04/02/sleep-variation-investigated/
	' If there's a long delay here it's because the system is busy; not interesting.
	debug_if_slow(large(starttime, waittime), 0.2, "")
	if setwait_called then
		setwait_called = NO
	else
		debug "dowait called without setwait"
	end if
	return timer >= flagtime
end function


'==========================================================================================
'                                           Music
'==========================================================================================


sub setupmusic
	music_init
	sound_init
	musicbackendinfo = music_get_info
	debuginfo musicbackendinfo
end sub

sub closemusic ()
	music_close
	sound_close
end sub

sub resetsfx ()
	' Stops playback and unloads cached sound effects
	sound_reset
end sub

sub loadsong (songname as string)
	music_play(songname, getmusictype(songname))
end sub

'Doesn't work in SDL_mixer for MIDI music, so avoid
'sub pausesong ()
'	music_pause()
'end sub
'
'sub resumesong ()
'	music_resume
'end sub

function get_music_volume () as single
	return music_getvolume
end function

sub set_music_volume (byval vol as single)
	music_setvolume(vol)
end sub


'==========================================================================================
'                                      Sound effects
'==========================================================================================


' loopcount N to play N+1 times, -1 to loop forever
' See set_sfx_volume for description of volume_mult.
sub playsfx (num as integer, loopcount as integer = 0, volume_mult as single = 1.)
	dim slot as integer
	' If already loaded can reuse without reloading.
	' TODO: However this preempts it if still playing; shouldn't force that
	' NOTE: backends vary, music_sdl does nothing if too many sfx playing,
	' music_audiere has no limit.
	slot = sound_slot_with_id(num)
	if slot = -1 then
		slot = sound_load(find_sfx_lump(num), num)
		if slot = -1 then exit sub
	end if
	'debug "playsfx volume_mult=" & volume_mult & " global_sfx_volume " & global_sfx_volume
	sound_play(slot, loopcount, volume_mult * global_sfx_volume)
	sound_slotdata(slot)->original_volume = volume_mult
end sub

sub stopsfx (num as integer)
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then exit sub
	sound_stop(slot)
end sub

sub pausesfx (num as integer)
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then exit sub
	sound_pause(slot)
end sub

' This returns the actual effective sfx volume 0. - 1., combining all volume
' settings and any fade effects the backend might be doing (nothing like
' that is implemented yet).
function effective_sfx_volume (num as integer) as single
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then return 0.
	return sound_getvolume(slot)
end function

/'  Is this needed?
function get_sfx_volume (num as integer) as single
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then return 0.
	return sound_getslot(slot)->original_volume
end function
'/

' Set the volume of a sfx to some multiple of its default volume,
' which is the global sfx volume * the volume adjustment defined in Custom
sub set_sfx_volume (num as integer, volume_mult as single)
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then exit sub
	sound_setvolume(slot, volume_mult * global_sfx_volume)
	sound_slotdata(slot)->original_volume = volume_mult
end sub

' Set the global volume multiplier for sound effects.
' The backends only support a max volume of 1.0,
' but the global volume can be set higher, amplifying
' any sfx with a volume less than 1.0.
sub set_global_sfx_volume (volume as single)
	global_sfx_volume = volume
	' Update all SFX
	for slot as integer = 0 to sound_lastslot()
		dim slotdata as SFXCommonData ptr
		slotdata = sound_slotdata(slot)
		if slotdata = 0 then continue for
		'debug "set_global_sfx_volume: refresh volume for " _
		'      & slotdata->effectID & " to " & (slotdata->original_volume * global_sfx_volume)
		sound_setvolume slot, slotdata->original_volume * global_sfx_volume
	next
end sub

function get_global_sfx_volume () as single
	return global_sfx_volume
end function

' Only used by Custom's importing interface
sub freesfx (byval num as integer)
	sound_free(num)
end sub

function sfxisplaying(byval num as integer) as bool
	dim slot as integer
	slot = sound_slot_with_id(num)
	if slot = -1 then return NO
	return sound_playing(slot)
end function


'==========================================================================================
'                                      Keyboard input
'==========================================================================================

function real_keyval(byval a as integer, byval repeat_wait as integer = 0, byval repeat_rate as integer = 0) as integer
	return keyval(a, repeat_wait, repeat_rate, YES)
end function

function keyval (byval a as integer, byval repeat_wait as integer = 0, byval repeat_rate as integer = 0, real_keys as bool = NO) as integer
'except for special keys (like -1), each key reports 3 bits:
'
'bit 0: key was down at the last setkeys call
'bit 1: keypress event (either new keypress, or key-repeat) during last setkey-setkey interval
'bit 2: new keypress during last setkey-setkey interval
'
'Note: Alt/Ctrl keys may behave strangely with gfx_fb (and old gfx_directx):
'You won't see Left/Right keypresses even when scAlt/scCtrl is pressed, so do not
'check "keyval(scLeftAlt) > 0 or keyval(scRightAlt) > 0" instead of "keyval(scAlt) > 0"

	dim kbstate as KeyboardState ptr
	if replay.active andalso real_keys = NO then
		kbstate = @replay_kb
	else
		kbstate = @real_kb
	end if
	dim result as integer = kbstate->keybd(a)

	if a >= 0 then
		if repeat_wait = 0 then repeat_wait = kbstate->keyrepeatwait
		if repeat_rate = 0 then repeat_rate = kbstate->keyrepeatrate

		'awful hack to avoid arrow keys firing alternatively when not pressed at the same time:
		'save state of the first arrow key you query
		dim arrowkey as bool = NO
		if a = scLeft or a = scRight or a = scUp or a = scDown then arrowkey = YES
		if arrowkey and kbstate->diagonalhack <> -1 then return (result and 5) or (kbstate->diagonalhack and result > 0)

		if kbstate->key_down_ms(a) >= repeat_wait then
			dim check_repeat as bool = YES

			'if a = scAlt then
				'alt can repeat (probably a bad idea not to), but only if nothing else has been pressed
				'for i as integer = 1 to scLAST
				'	if kbstate->keybd(i) > 1 then check_repeat = NO
				'next
				'if delayed_alt_keydown = NO then check_repeat = NO
			'end if

			'Don't fire repeat presses for special toggle keys (note: these aren't actually
			'toggle keys in all backends, eg. gfx_fb)
			if a = scNumlock or a = scCapslock or a = scScrolllock then check_repeat = NO

			if check_repeat then
				'Keypress event at "wait + i * rate" ms after keydown
				dim temp as integer = kbstate->key_down_ms(a) - repeat_wait
				if temp \ repeat_rate > (temp - kbstate->setkeys_elapsed_ms) \ repeat_rate then result or= 2
			end if
			if arrowkey then kbstate->diagonalhack = result and 2
		end if
	end if
	return result
end function

sub setkeyrepeat (byval repeat_wait as integer = 500, byval repeat_rate as integer = 55)
	if replay.active then
		replay_kb.keyrepeatwait = repeat_wait
		replay_kb.keyrepeatrate = repeat_rate
	else
		real_kb.keyrepeatwait = repeat_wait
		real_kb.keyrepeatrate = repeat_rate
	end if
end sub

' Get text input by assuming a US keyboard layout and reading scancodes rather than using the io backend.
' Also supports alt- combinations for the high 128 characters
' Always returns real input, even if replaying input.
function get_ascii_inputtext () as string
	dim shift as integer = 0
	dim ret as string

	if real_keyval(scCtrl) > 0 then return ""

	if real_keyval(scShift) and 1 then shift += 1
	if real_keyval(scAlt) and 1 then shift += 2   'for characters 128 and up

	for i as integer = 0 to 53
		dim effective_shift as integer = shift
		if shift <= 1 andalso real_keyval(scCapsLock) > 0 then
			select case i
				case scQ to scP, scA to scL, scZ to scM
					effective_shift xor= 1
			end select
		end if
		if real_keyval(i) > 1 then
			ret &= key2text(effective_shift, i)
		end if
	next i

	' A few keys missing from key2text
	if real_keyval(scSpace) > 1 then ret &= " "
	if real_keyval(scNumpadAsterisk) > 1 then ret &= "*"
	if real_keyval(scNumpadMinus) > 1 then ret &= "-"
	if real_keyval(scNumpadPlus) > 1 then ret &= "+"
	' (Bug: gfx_fb reports both scSlash and scNumpadSlash)
	if gfxbackend <> "fb" and real_keyval(scNumpadSlash) > 1 then ret &= "/"

	' Numpad is missing from key2text
	' (Bug: gfx_fb on Windows never reports scNumpad5 at all!)
	for i as integer = 0 to ubound(numpad2text)
		if real_keyval(scNumpad7 + i) > 1 then
			ret &= numpad2text(i)
		end if
        next
	' Note, we ignore numlock/shift, because backends/OSes differ on when
	' they report text input from numpad keys anyway:
	' X11 (both FB and SDL): when numlock XOR shift is pressed
	' Windows (both FB and SDL): only when numlock on and shift not pressed
	' gfx_directx: when numlock is on
	' (Also, on Windows, status of numlock is buggy: for gfx_sdl and gfx_directx,
	' after user turns it off, state doesn't update until next keypress,
	' while gfx_fb doesn't report it at all)

	return ret
end function

' Returns text input from the backend since the last call.
' Always returns real input, even if replaying input.
private function read_inputtext () as string
	if disable_native_text_input then
		return get_ascii_inputtext()
	end if

	'AFAIK, this is will still work on all platforms except X11 with SDL
	'even if inputtext was not enabled; however you'll get a warning when
	'getinputtext is called.
	dim w_in as wstring * 64
	if io_textinput then io_textinput(w_in, 64)

	'OK, so here's the hack: one of the alt keys (could be either) might be used
	'as a 'shift' or compose key, but if it's not, we want to support the old
	'method of entering extended characters (128 and up) using it. This will
	'backfire if the key face/base characters aren't ASCII

	dim force_native_input as bool = NO

	for i as integer = 0 to len(w_in) - 1
		if w_in[i] > 127 then force_native_input = YES
	next

	if force_native_input = NO andalso real_keyval(scAlt) and 1 then
		'Throw away w_in
		return get_ascii_inputtext()
	end if


	dim as integer icons_low, icons_high
	if get_font_type(current_font()) = ftypeLatin1 then
		icons_low = 127
		icons_high = 160
	else
		icons_low = 127
		icons_high = 255
	end if

	if io_textinput then
		'if len(w_in) then print #fh, "input :" & w_in
		' Now we need to convert from unicode to the game's character set (7-bit ascii or Latin-1)
		dim ret as string = ""
		dim force_shift as bool = NO
		for i as integer = 0 to len(w_in) - 1
			if w_in[i] > 255 then
				select case w_in[i]
					case &hF700 to &hF746:
						'Ignore Mac unicode for arrow keys, pgup+pgdown,
						' delete, misc other keys. I don't know if the
						' upper bound of &hF746 is high enough, but it
						' blocks all the keys I could find on my keyboard.
						' --James
						continue for
					case 304:
						'Ignore COMBINING MACRON on most platforms, but
						'use it to shift the next char on Android
#IFDEF __FB_ANDROID__
						force_shift = YES
#ENDIF
						continue for
				end select
				'debug "unicode char " & w_in[i]
				ret += "?"
			elseif w_in[i] = 127 then
				'Delete (only sent on OSX). Ignore; we use scancodes instead.
			elseif w_in[i] >= icons_low and w_in[i] <= icons_high then
				ret += "?"
			elseif w_in[i] < 32 then
				'Control character. What a waste of 8-bit code-space!
				'Note that we ignore newlines... because we've always done it that way
			else
				dim ch as string = chr(w_in[i])
				if force_shift then
					force_shift = NO
					ch = UCASE(ch)
					select case ch
						'FIXME: it would be better to loop through the key2text array
						'here, but it fails to initialize on Android
						case "1": ch = "!"
						case "2": ch = "@"
						case "3": ch = "#"
						case "4": ch = "$"
						case "5": ch = "%"
						case "6": ch = "^"
						case "7": ch = "&"
						case "8": ch = "*"
						case "9": ch = "("
						case "0": ch = ")"
						case "-": ch = "_"
						case "=": ch = "+"
						case "[": ch = "{"
						case "]": ch = "}"
						case ";": ch = ":"
						case "'": ch = """"
						case "`": ch = "~"
						case "\": ch = "|"
						case ",": ch = "<"
						case ".": ch = ">"
						case "/": ch = "?"
					end select
				end if
				ret += ch
			end if
		next
		return ret
	else
		return get_ascii_inputtext()
	end if
end function

'If using gfx_sdl and gfx_directx this is Latin-1, while gfx_fb doesn't currently support even that
function getinputtext () as string
	if replay.active then
		return replay_kb.inputtext
	end if

	if disable_native_text_input = NO then
		'Only show this message if getinputtext is called incorrectly twice in a row,
		'to filter out instances when a menu with inputtext disabled exits back to
		'one that expects it enabled, and getinputtext is called before the next call to setkeys.
		static last_call_was_bad as bool = NO
		if inputtext_enabled = NO and last_call_was_bad then
			debuginfo "getinputtext: not enabled"
		end if
		last_call_was_bad = (inputtext_enabled = NO)
	end if

	return real_kb.inputtext
end function

'Checks the keyboard and optionally joystick for keypress events.
'trigger_level: 0 to trigger on a held key,
'               1 to trigger only on new keypress or repeat.
'Returns scancode if one is found, 0 otherwise.
'Use this instead of looping over all keys, to make sure alt filtering and joysticks work
function anykeypressed (checkjoystick as bool = YES, checkmouse as bool = YES, trigger_level as integer = 1) as integer
	dim as integer joybutton, joyx, joyy

	for i as integer = 0 to scLAST
		'check scAlt only, so Alt-filtering (see setkeys) works
		if i = scLeftAlt or i = scRightAlt or i = scUnfilteredAlt then continue for
		' Ignore capslock and numlock because they always appear pressed when on,
		' and it doesn't really matter if they doesn't work for 'press a key' prompts.
		' To be on the safe said, ignore scroll lock too. Though with gfx_sdl,
		' on Windows howing down scrolllock causes SDL to report key_up/key_down
		' wait every tick, while on linux it seems to behave like a normal key
		if i = scCapsLock or i = scNumLock or i = scScrollLock then continue for

		if keyval(i) > trigger_level then
			return i
		end if
	next
	if checkjoystick then
		dim starttime as double = timer
		if io_readjoysane(0, joybutton, joyx, joyy) then
			for i as integer = 16 to 1 step -1
				if joybutton and (i ^ 2) then return (scJoyButton1 - 1) + i
			next i
		end if
		debug_if_slow(starttime, 0.01, "io_readjoysane")
	end if

	if checkmouse then
		dim bitvec as integer = iif(trigger_level >= 1, mouse_state.release, mouse_state.buttons)
		for button as integer = 0 to 15
			if bitvec and (1 shl button) then
				return scMouseLeft + button
			end if
		next button
	end if
end function

'Waits for a new keyboard key, mouse or joystick button press. Returns the scancode
function waitforanykey () as integer
	dim as integer key, sleepjoy = 3
	dim remem_speed_control as bool = use_speed_control
	use_speed_control = YES
	skipped_frame.show()  'If we frame-skipped last frame, better show it
	setkeys
	do
		setwait 60, 200
		io_pollkeyevents()
		setkeys
		key = anykeypressed(sleepjoy = 0, YES, 3)  'New keypresses only
		if key then
			snapshot_check  'In case F12 pressed, otherwise it wouldn't work
			setkeys  'Clear the keypress
			use_speed_control = remem_speed_control
			return key
		end if
		if sleepjoy > 0 then
			sleepjoy -= 1
		end if
		if dowait then
			' Redraw the screen occasionally in case something like an overlay is drawn
			setvispage getvispage, , YES  'Preserve contents
		end if
	loop
end function

'Wait for all keys, and joystick and mouse buttons to be released
sub waitforkeyrelease ()
	setkeys
	'anykeypressed checks scAlt instead of scUnfilteredAlt
	while anykeypressed(YES, YES, 0) or keyval(scUnfilteredAlt)
		if getquitflag() then exit sub
		io_pollkeyevents()
		setwait 15
		setkeys
		dowait
	wend
end sub

'Without changing the results of keyval or readmouse, check whether a key has been pressed,
'mouse button clicked, or window close requested since the last call to setkeys.
'NOTE: any such keypresses or mouse clicks are lost! This is OK for the current purposes
'NOTE: This checks the real keyboard state while replaying input.
function interrupting_keypress () as bool
	dim starttime as double = timer
	dim ret as bool = NO

	io_pollkeyevents()

	dim keybd_dummy(scLAST) as integer
	dim mouse as MouseInfo

	mutexlock keybdmutex
	io_keybits(@keybd_dummy(0))
	io_mousebits(mouse.x, mouse.y, mouse.wheel, mouse.buttons, mouse.clicks)
	mutexunlock keybdmutex

	debug_if_slow(starttime, 0.005, "")

	' Check for attempt to quit program
	if keybd_dummy(scPageup) > 0 and keybd_dummy(scPagedown) > 0 and keybd_dummy(scEsc) > 1 then closerequest = YES
	if closerequest then
#ifdef IS_GAME
		exit_gracefully()
#else
		ret = YES
#endif
	end if

	for i as integer = 0 to scLAST
		'Check for new keypresses
		if keybd_dummy(i) and 2 then ret = YES
	next

	if mouse.clicks then ret = YES

	if ret then
		'Crap, this is going to desync the replay since the result of interrupting_keypress isn't recorded
		'(No problem if paused)
		if record.active then
			stop_recording_input "Recording ended by interrupting keypress"
		end if
		if replay.active then
			stop_replaying_input "Replay ended by interrupting keypress"
		end if
	end if

	return ret
end function

'Poll io backend to update key state bits, and then handle all special scancodes.
'keybd() should be dimmed at least (0 to scLAST)
sub setkeys_update_keybd (keybd() as integer, byref delayed_alt_keydown as bool)
	dim winstate as WindowState ptr
	winstate = gfx_getwindowstate()

	mutexlock keybdmutex
	io_keybits(@keybd(0))
	mutexunlock keybdmutex

	'State of keybd(0 to scLAST) at this point:
	'bit 0: key currently down
	'bit 1: key down since last io_keybits call
	'bit 2: zero

	'debug "raw scEnter = " & keybd(scEnter) & " scAlt = " & keybd(scAlt)

	'DELETEME (after a lag period): This is a temporary fix for gfx_directx not knowing about scShift
	'(or any other of the new scancodes, but none of the rest matter much (maybe
	'scPause) since there are no games that use them).
	'(Ignore bit 2, because that isn't set yet)
	if ((keybd(scLeftShift) or keybd(scRightShift)) and 3) <> (keybd(scShift) and 3) then
		keybd(scShift) = keybd(scLeftShift) or keybd(scRightShift)
	end if

	keybd(scAnyEnter) = keybd(scEnter) or keybd(scNumpadEnter)

	'Backends don't know about scAlt, only scUnfilteredAlt
	keybd(scAlt) = keybd(scUnfilteredAlt)

	'Don't fire ctrl presses when alt down due to large number of WM shortcuts containing ctrl+alt
	'(Testing delayed_alt_keydown is just a hack to add one tick delay after alt up,
	'which is absolutely required)
	if (keybd(scAlt) and 1) or delayed_alt_keydown then

		if keybd(scEnter) and 6 then
			keybd(scEnter) and= 1
			delayed_alt_keydown = NO
		end if

		keybd(scCtrl) and= 1
		keybd(scLeftCtrl) and= 1
		keybd(scRightCtrl) and= 1
	end if

	'Calculate new "new keypress" bit (bit 2)
	for a as integer = 0 to scLAST
		keybd(a) and= 3
		if a = scAlt then
			'Special behaviour for alt, to ignore pesky WM shortcuts like alt+tab, alt+enter:
			'Wait until alt has been released, without losing focus, before
			'causing a key-down event.
			'Also, special case for alt+enter, since that doesn't remove focus

			'Note: this is only for scAlt, not scLeftAlt, scRightAlt, which aren't used by
			'the engine, only by games. Maybe those shoudl be blocked too
			'Note: currently keyval causes key-repeat events for alt if delayed_alt_keydown = YES

			if keybd(scAlt) and 2 then
				if delayed_alt_keydown = NO then
					keybd(scAlt) -= 2
				end if
				delayed_alt_keydown = YES
			end if

			/'
			for scancode as integer = 0 to scLAST
				if scancode <> scUnfilteredAlt and scancode <> scAlt and scancode <> scLeftAlt and scancode <> scRightAlt and (keybd(scancode) and 1) then
					delayed_alt_keydown = NO
				end if
			next
			'/
			if winstate andalso winstate->focused = NO then
				delayed_alt_keydown = NO
			end if

			if (keybd(scAlt) and 1) = 0 andalso delayed_alt_keydown then
				keybd(scAlt) or= 6
				delayed_alt_keydown = NO
			end if

		'elseif a = scCtrl or a = scLeftCtrl or a = scRightCtrl then

		else
			'Duplicate bit 1 to bit 2
			 keybd(a) or= (keybd(a) and 2) shl 1
		end if
	next

end sub

' Updates kbstate.key_down_ms
sub update_keydown_times (kbstate as KeyboardState)
	'reset arrow key fire state
	kbstate.diagonalhack = -1

	for a as integer = 0 to scLAST
		if (kbstate.keybd(a) and 4) or (kbstate.keybd(a) and 1) = 0 then
			kbstate.key_down_ms(a) = 0
		end if
		if kbstate.keybd(a) and 1 then
			kbstate.key_down_ms(a) += kbstate.setkeys_elapsed_ms
		end if
	next
end sub

sub setkeys (byval enable_inputtext as bool = NO)
'Updates the keyboard state to reflect new keypresses
'since the last call, also clears all keypress events (except key-is-down)
'
'Also calls allmodex_controls() to handle key hooks which work everywhere.
'
'enable_inputtext needs to be true for getinputtext to work;
'however there is a one tick delay before coming into effect.
'Passing enable_inputtext may cause certain "combining" keys to stop reporting
'key presses. Currently this only happens with gfx_sdl on X11 (it is an X11
'limitation). And it probably only effects punctuation keys such as ' or ~
'(naturally those keys could be anywhere, but a good rule of thumb seems to be
'to avoid QWERTY punctuation keys)
'For more, see http://en.wikipedia.org/wiki/Dead_key
'
'Note that key repeat is NOT added to kb.keybd() (it's done by "post-processing" in keyval)

	dim starttime as double = timer

	if replay.active = NO and disable_native_text_input = NO then
		if enable_inputtext then enable_inputtext = YES
		if inputtext_enabled <> enable_inputtext then
			inputtext_enabled = enable_inputtext
			io_enable_textinput(inputtext_enabled)
		end if
	end if

	'While playing back a recording we still poll for keyboard
	'input, but this goes in the separate real_kb.keybd() array so it's
	'invisible to the game.

	' Get real keyboard state
	real_kb.setkeys_elapsed_ms = bound(1000 * (TIMER - last_setkeys_time), 0, 255)
	last_setkeys_time = TIMER
	setkeys_update_keybd real_kb.keybd(), real_kb.delayed_alt_keydown
	update_keydown_times real_kb
	real_kb.inputtext = read_inputtext()

	if replay.active then
		' Updates replay_kb.keybd(), .setkeys_elapsed_ms,  and .inputtext
		replay_input_tick ()

		' Updates replay_kb.key_down_ms(), .diagonalhack
		update_keydown_times replay_kb
	end if

	'Taking a screenshot with gfx_directx is very slow, so avoid timing that
	debug_if_slow(starttime, 0.01, replay.active)

	'Handle special keys, possibly clear or add keypresses. Might recursively call setkeys.
	allmodex_controls()

	' Record input, after filtering of keys by allmodex_controls.
	if record.active then
		record_input_tick ()
	end if

	' Call io_mousebits
	update_mouse_state()

	' Custom/Game-specific global controls, done last so that there can't be interference
	static entered as bool
	if entered = NO then
		entered = YES
		global_setkeys_hook
		entered = NO
	end if
end sub

'Erase a keypress from the keyboard state.
sub clearkey(byval k as integer)
	if replay.active then
		replay_kb.keybd(k) = 0
		replay_kb.key_down_ms(k) = 0
	else
		real_kb.keybd(k) = 0
		real_kb.key_down_ms(k) = 0
	end if
end sub

'Clear the new keypress flag for a key.
sub clear_newkeypress(k as integer)
	if replay.active then
		replay_kb.keybd(k) and= 1
	else
		real_kb.keybd(k) and= 1
	end if
end sub

'Erase a keypress from the real keyboard state even if replaying recorded input.
sub real_clearkey(byval k as integer)
	real_kb.keybd(k) = 0
	real_kb.key_down_ms(k) = 0
end sub

'Clear the new keypress flag for a key. Real keyboard state even if replaying recorded input.
sub real_clear_newkeypress(k as integer)
	real_kb.keybd(k) and= 1
end sub

sub setquitflag (newstate as bool = YES)
	closerequest = newstate
end sub

function getquitflag () as bool
	return closerequest
end function

' This callback is used by backends.
' Returns INT_MIN if the event was not understood, otherwise return value is event-dependent.
function post_event cdecl (event as EventEnum, arg1 as intptr_t = 0, arg2 as intptr_t = 0) as integer
	select case event
	case eventTerminate
		closerequest = YES
		return 0
	case eventFullscreened
		'arg1 is the new state
		user_toggled_fullscreen = YES
		return 0
	end select
	debuginfo "post_event: unknown event " & event & " " & arg1 & " " & arg2
	return INT_MIN
end function

sub post_terminate_signal cdecl ()
	closerequest = YES
end sub


'==========================================================================================
'                                          Mouse
'==========================================================================================


function havemouse() as bool
	'atm, all backends support the mouse, or don't know
	return YES
end function

' Cause mouse cursor to be always hidden
sub hidemousecursor ()
	io_setmousevisibility(cursorHidden)
	cursorvisibility = cursorHidden
end sub

' Cause mouse cursor to be always visible, except on touchscreen devices
sub showmousecursor ()
	io_setmousevisibility(cursorVisible)
	cursorvisibility = cursorVisible
end sub

' Use when the mouse is not in use:
' Hide the mouse cursor in fullscreen, and show it when windowed.
sub defaultmousecursor ()
	io_setmousevisibility(cursorDefault)
	cursorvisibility = cursorDefault
end sub

sub setcursorvisibility (state as CursorVisibility)
	select case state
	case cursorVisible, cursorHidden, cursorDefault
		io_setmousevisibility(state)
		cursorvisibility = state
	case else
		showerror "Bad setcursorvisibility(" & state & ") call"
	end select
end sub

function getcursorvisibility () as CursorVisibility
	return cursorvisibility
end function

sub check_for_released_mouse_button(byval buttonnum as MouseButton)
	if (mouse_state.last_buttons and buttonnum) andalso (mouse_state.buttons and buttonnum) = 0 then
		'If the button was released since the last tick, turn on .release
		mouse_state.release or= buttonnum
	else
		'All the rest of the time, .release should be off
		mouse_state.release and= not buttonnum
	end if
end sub

' Called from setkeys to update the internal mouse state
sub update_mouse_state ()
	dim starttime as double = timer

	dim lastpos as XYPair = mouse_state.pos

	mouse_state.last_buttons = mouse_state.buttons

	mutexlock keybdmutex   'Just in case
	io_mousebits(mouse_state.x, mouse_state.y, mouse_state.wheel, mouse_state.buttons, mouse_state.clicks)
	mutexunlock keybdmutex

	for button as integer = 0 to 15
		check_for_released_mouse_button(1 shl button)
	next

	mouse_state.wheel *= -1
	mouse_state.wheel_delta = mouse_state.wheel - last_mouse_wheel
	mouse_state.wheel_clicks = mouse_state.wheel \ 120 - last_mouse_wheel \ 120
	last_mouse_wheel = mouse_state.wheel

	'Ignore mouse clicks that focus the window. If you clicked, it's already
	'focused, so we consider the previous focus state instead.
	'FIXME: this doesn't seem to work with gfx_sdl on X11
	static prev_focus_state as bool
	if prev_focus_state = NO then
		mouse_state.buttons = 0
		mouse_state.clicks = 0
	end if
	dim window_state as WindowState ptr = gfx_getwindowstate()
	prev_focus_state = window_state->focused

	'gfx_fb/sdl/alleg return last onscreen position when the mouse is offscreen
	'gfx_fb: If you release a mouse button offscreen, it becomes stuck (FB bug)
	'        wheel scrolls offscreen are registered when you move back onscreen
	'        Also, may report a mouse position slightly off the screen edge
	'        (at least on X11) due to freezing mouse input fractionally late.
	'gfx_alleg: button state continues to work offscreen but wheel scrolls are not registered
	'gfx_sdl: button state works offscreen. Wheel movement is reported if the
	'         mouse is over the window, even if it's not focused. SDL 1.2 doesn't
	'         know about the OS's wheel speed setting.

	mouse_state.moved = lastpos <> mouse_state.pos

	mouse_state.active = window_state->mouse_over and window_state->focused

	'Behaviour of clicking and dragging from inside the window to outside:
	'gfx_fb:  Mouse input goes dead while outside until moved back into window.
	'         When button is released, the cursor reappears at actual position on-screen
	'gfx_sdl: Mouse acts as if clipped to the window while button is down; but when it's released
	'         it appears at its actual position on-screen
	'directx: Mouse is truely clipped to the window while button is down.
	'gfx_alleg:Unknown.

	if mouse_state.dragging then
		'Test whether drag ended
		if (mouse_state.clicks and mouse_state.dragging) orelse (mouse_state.buttons and mouse_state.dragging) = 0 then
			mouse_state.dragging = 0
			mouse_state.clickstart = XY(0, 0)
		end if
	else
		'Dragging is only tracked for a single button at a time, and clickstart is not updated
		'while dragging either. So we may now test for new drags or clicks.
		for button as integer = 0 to 15
			dim mask as MouseButton = 1 shl button
			if mouse_state.clicks and mask then
				'Do not flag as dragging until the second tick
				mouse_state.clickstart = mouse_state.pos
			elseif mouse_state.buttons and mask then
				'Button still down
				mouse_state.dragging = mask
				exit for
			end if
		next
	end if

	' If you released a mouse grab (mouserect) and then click on the
	' window, resume the mouse grab.
	if mouse_state.clicks <> 0 then
		if mouse_grab_requested andalso mouse_grab_overridden then
			mouserect remember_mouse_grab(0), remember_mouse_grab(1), remember_mouse_grab(2), remember_mouse_grab(3)
		end if
	end if

	debug_if_slow(starttime, 0.005, mouse_state.clicks)
end sub

' Get the state of the mouse at the last setkeys call (or after putmouse, mouserect).
' So make sure you call this AFTER setkeys.
function readmouse () byref as MouseInfo
	return mouse_state
end function

sub MouseInfo.clearclick(button as MouseButton)
	clicks and= not button
	release and= not button
	' Cancel for good measure, but not really needed
	dragging and= not button
end sub

sub movemouse (byval x as integer, byval y as integer)
	io_setmouse(x, y)

	' Don't call io_mousebits to get the new state, since that will cause clicks and movements to get lost,
	' and is difficult to support in .ohrkeys.
	mouse_state.x = x
	mouse_state.y = y
end sub

sub mouserect (byval xmin as integer, byval xmax as integer, byval ymin as integer, byval ymax as integer)
	' Set window title to tell the player about scrolllock to escape mouse-grab
	' gfx_directx does this itself, including handling scroll lock
	if gfxbackend = "fb" or gfxbackend = "sdl" then
		if xmin = -1 and xmax = -1 and ymin = -1 and ymax = -1 then
			mouse_grab_requested = NO
			settemporarywindowtitle remember_title
		else
			remember_mouse_grab(0) = xmin
			remember_mouse_grab(1) = xmax
			remember_mouse_grab(2) = ymin
			remember_mouse_grab(3) = ymax
			mouse_grab_requested = YES
			mouse_grab_overridden = NO
#IFDEF __FB_DARWIN__
			settemporarywindowtitle remember_title & " (F14 to free mouse)"
#ELSE
			settemporarywindowtitle remember_title & " (ScrlLock to free mouse)"
#endIF
		end if
	end if
	mutexlock keybdmutex
	io_mouserect(xmin, xmax, ymin, ymax)
	mutexunlock keybdmutex

	' Don't call io_mousebits to get the new state, since that will cause clicks and movements to get lost,
	' and is difficult to support in .ohrkeys.
	mouse_state.x = bound(mouse_state.x, xmin, xmax)
	mouse_state.y = bound(mouse_state.y, ymin, ymax)
end sub


'==========================================================================================
'                                        Joystick
'==========================================================================================


function readjoy (joybuf() as integer, byval jnum as integer) as bool
'Return false if joystick is not present, or true if joystick is present.
'(Warning: if gfx_directx can't read a joystick, it is removed and the others
'are renumbered)
'jnum is the joystick to read
'joybuf(0) = Analog X axis (scaled to -100 to 100)
'joybuf(1) = Analog Y axis
'joybuf(2) = button 1: 0=pressed nonzero=not pressed
'joybuf(3) = button 2: 0=pressed nonzero=not pressed
'Other values in joybuf() should be preserved.
'If X and Y axis are not analog,
'  upward motion when joybuf(0) < joybuf(9)
'  down motion when joybuf(0) > joybuf(10)
'  left motion when joybuf(1) < joybuf(11)
'  right motion when joybuf(1) > joybuf(12)
	dim starttime as double = timer
	dim as integer buttons, x, y
	dim ret as bool
	ret = io_readjoysane(jnum, buttons, x, y)
	if ret then
		joybuf(0) = x
		joybuf(1) = y
		joybuf(2) = (buttons AND 1) = 0 '0 = pressed, not 0 = unpressed (why???)
		joybuf(3) = (buttons AND 2) = 0 'ditto
		ret = YES
	end if
	debug_if_slow(starttime, 0.01, jnum & " = " & buttons)
	return ret
end function

function readjoy (byval joynum as integer, byref buttons as integer, byref x as integer, byref y as integer) as bool
	dim starttime as double = timer
	dim ret as bool = io_readjoysane(joynum, buttons, x, y)
	debug_if_slow(starttime, 0.01, joynum & " = " & buttons)
	return ret
end function


'==========================================================================================
'                       Compat layer for old graphics backend IO API
'==========================================================================================
' These functions are used to supplement gfx backends not supporting
' io_mousebits or io_keybits.

'these are wrappers provided by the polling thread
sub io_amx_keybits cdecl (byval keybdarray as integer ptr)
	for a as integer = 0 to scLAST
		keybdarray[a] = keybdstate(a)
		keybdstate(a) = keybdstate(a) and 1
	next
end sub

sub io_amx_mousebits cdecl (byref mx as integer, byref my as integer, byref mwheel as integer, byref mbuttons as integer, byref mclicks as integer)
	'get the mouse state one last time, for good measure
	io_getmouse(mx, my, mwheel, mbuttons)
	mclicks = mouseflags or (mbuttons and not mouselastflags)
	mouselastflags = mbuttons
	mouseflags = 0
	mbuttons = mbuttons or mclicks
end sub

private sub pollingthread(byval unused as any ptr)
	dim as integer a, dummy, buttons

	while endpollthread = NO
		mutexlock keybdmutex

		dim starttime as double = timer

		io_updatekeys(@keybdstate(0))
		debug_if_slow(starttime, 0.005, "io_updatekeys")
		starttime = timer

		'set key state for every key
		'highest scancode in fbgfx.bi is &h79, no point overdoing it
		for a = 0 to scLAST
			if keybdstate(a) and 8 then
				'decide whether to set the 'new key' bit, otherwise the keystate is preserved
				if (keybdstate(a) and 1) = 0 then
					'this is a new keypress
					keybdstate(a) = keybdstate(a) or 2
				end if
			end if
			'move the bit (clearing it) that io_updatekeys sets from 8 to 1
			keybdstate(a) = (keybdstate(a) and 2) or ((keybdstate(a) shr 3) and 1)
		next

		io_getmouse(dummy, dummy, dummy, buttons)
		mouseflags = mouseflags or (buttons and not mouselastflags)
		mouselastflags = buttons

		mutexunlock keybdmutex

		debug_if_slow(starttime, 0.01, "io_getmouse")

		'25ms was found to be sufficient
		sleep 25
	wend
end sub


'==========================================================================================
'                              Special overlays and controls
'==========================================================================================


'Called from setkeys. This handles keypresses which are global throughout the engine.
'(Note that backends also have some hooks, especially gfx_sdl.bas for OSX-specific stuff)
private sub allmodex_controls()
	'Check to see if the backend has received a request
	'to close the window (eg. clicking the window frame's X).
	'This form of input isn't recorded, but the ESCs fired in Custom will be recorded,
	'so there's no need to check the recorded key state for pageup+pagedown+esc
	if real_keyval(scPageup) > 0 and real_keyval(scPagedown) > 0 and real_keyval(scEsc) > 1 then closerequest = YES

#ifdef IS_CUSTOM
	'Fire ESC keypresses to exit every menu
	if closerequest then
		if replay.active or replay.paused then
			stop_replaying_input "Replay ended by quit request"
		end if
		real_kb.keybd(scEsc) = 7
	end if
#elseif defined(IS_GAME)
	'Quick abort (could probably do better, just moving this here for now)
	if closerequest then
		exit_gracefully()
	end if
#endif

	' Crash the program! For testing
	if keyval(scPageup) > 0 and keyval(scPagedown) > 0 and keyval(scF4) > 1 then
		dim invalid as integer ptr
		*invalid = 0
	end if

	' A breakpoint. If not running under gdb, this will terminate the program
	if keyval(scTab) > 0 and keyval(scShift) > 0 and keyval(scF4) > 1 then
		interrupt_self ()
	end if

	if keyval(scCtrl) > 0 and keyval(scF8) > 1 then
		gfx_backend_menu
	end if

	' F12 screenshots are handled in setvispage, not here.

	' Ctrl+F12 to start/stop recording a .gif
	if real_keyval(scCtrl) > 0 andalso (real_keyval(scF12) and 4) then
		toggle_recording_gif
	end if

	if real_keyval(scCtrl) > 0 and real_keyval(scTilde) and 4 then
		toggle_fps_display
	end if

	fps_multiplier = base_fps_multiplier
	if real_keyval(scShift) > 0 and real_keyval(scTab) > 0 then  'speed up while held down
		fps_multiplier *= 6.
	end if

	if replay.active then replay_controls()

	if real_keyval(scCtrl) > 0 and real_keyval(scF11) > 1 then
		real_clearkey(scF11)
		macro_controls()
	end if

	'This is a pause that doesn't show up in recorded input
	if (replay.active or record.active) and real_keyval(scPause) > 1 then
		real_clearkey(scPause)
		pause_replaying_input
		pause_recording_input
		notification "Replaying/recording is PAUSED"
		resume_replaying_input
		resume_recording_input
	end if

	'Some debug keys for working on resolution independence
	if keyval(scShift) > 0 and keyval(sc1) > 0 then
		if keyval(scRightBrace) > 1 then
			set_resolution windowsize.w + 10, windowsize.h + 10
		end if
		if keyval(scLeftBrace) > 1 then
			set_resolution windowsize.w - 10, windowsize.h - 10
		end if
		if keyval(scR) > 1 then
			'Note: there's also a debug key in the F8 menu in-game.
			resizing_enabled = gfx_set_resizable(resizing_enabled xor YES, minwinsize.w, minwinsize.h)
		end if
	end if

	if mouse_grab_requested then
#IFDEF __FB_DARWIN__
		if keyval(scF14) > 1 then
			clearkey(scF14)
#ELSE
		if keyval(scScrollLock) > 1 then
			clearkey(scScrollLock)
#ENDIF
			mouserect -1, -1, -1, -1
			mouse_grab_requested = YES
			mouse_grab_overridden = YES
		end if
	end if
end sub

'Show the menu that comes up when pressing ESC while replaying
private sub replay_menu ()
	dim menu(...) as string = {"Resume Replay", "End Replay"}
	dim choice as integer
	pause_replaying_input
	ensure_normal_palette
	dim previous_speed as double = base_fps_multiplier
	base_fps_multiplier = 1.
	choice = multichoice("Stop replaying recorded input?", menu(), 0, 0)
	if choice = 0 then
		base_fps_multiplier = previous_speed
                resume_replaying_input
	elseif choice = 1 then
		stop_replaying_input "Playback cancelled."
	end if
	restore_previous_palette
end sub

'Controls available while replaying input.
'Called from inside setkeys; but it's OK to call setkeys from here if
'pause_replaying_input is called first. If FB had co-routines, this would be implemented as one.
private sub replay_controls ()
	'We call show_help which calls setkeys which calls us.
	static reentering as bool = NO
	if reentering then showerror "Reentry of replay_controls shouldn't occur"
	reentering = YES

	if real_keyval(scF1) > 1 then
		dim remem as bool = overlay_replay_display
		pause_replaying_input()
		hide_overlays()
		base_fps_multiplier = 1.
		show_help("share_replay")
		setkeys
		clearkey(scEsc)
		overlay_replay_display = remem
		resume_replaying_input()
	end if
	if real_keyval(scSpace) > 1 then
		overlay_replay_display xor= YES
	end if
	if real_keyval(scEsc) > 1 then
		replay_menu
	end if
	'Also scPause, handled in setkeys because it affects record too.

	if real_keyval(scLeft) > 1 then
		base_fps_multiplier *= 0.5
		show_replay_overlay()
	end if
	if real_keyval(scRight) > 1 then
		base_fps_multiplier *= 2
		show_replay_overlay()
	end if
	base_fps_multiplier = bound(base_fps_multiplier, 0.5^3, 2.^9)

	reentering = NO
end sub

' Menu of options for playback/recording of macros
private sub macro_menu ()
	pause_replaying_input
	pause_recording_input
	ensure_normal_palette
	dim holdscreen as integer = allocatepage
	copypage vpage, holdscreen

	dim choice as integer = 3  'Default to playback
	do
		'browse() and inputfilename() clobber vpage
		copypage holdscreen, vpage
		fuzzyrect 0, 0, , , uilook(uiBackground), vpage, 40

		redim menu(2) as string
		menu(0) = "Cancel"
		menu(1) = "Load macro from file"
		menu(2) = "Start recording macro"
		if isfile(macrofile) then
			redim preserve menu(5)
			menu(3) = "Play back last recorded macro"
			menu(4) = "Play back last recorded macro # times"
			menu(5) = "Save last recorded macro to file"
		end if

		dim msg as string
		msg = !"Macro Recording & Replay\n(See F1 help file for information.)"
		if ubound(menu) < 3 then
			msg += !"\nNo macro recorded yet."
		end if
		choice = multichoice(msg, menu(), choice, 0, "share_macro_menu")
		if choice = 1 then
			dim macfile as string
			macfile = browse(0, "", "*.ohrkeys")
			if len(macfile) then
				if not copyfile(macfile, macrofile) THEN
					visible_debug "ERROR: couldn't make a copy of " & macfile
				end if
			end if
			continue do
		elseif choice = 2 then
			show_overlay_message "Recording macro, CTRL+F11 to stop", 2.
			start_recording_input macrofile
		elseif choice = 3 then
			show_overlay_message "Replaying macro"
			start_replaying_input macrofile
		elseif choice = 4 then
			dim repeats as string
			prompt_for_string repeats, "Number of macro repetitions?"
			dim repeat_count as integer = str2int(repeats, -1)
			if repeat_count <= 0 then
				exit sub
			end if
			show_overlay_message "Replaying macro " & replay.repeat_count & " time(s)"
			start_replaying_input macrofile, repeat_count
		elseif choice = 5 then
			dim macfile as string
			macfile = inputfilename("Input a filename to save to", ".ohrkeys", "", "")
			'setkeys
			if len(macfile) then
				if not copyfile(macrofile, macfile + ".ohrkeys") THEN
					visible_debug "ERROR: couldn't write to " & macfile & ".ohrkeys"
				end if
			end if
			continue do
		end if
		exit do
	loop

	copypage holdscreen, vpage
	freepage holdscreen
	restore_previous_palette
	resume_replaying_input
	resume_recording_input
end sub

'Handles Ctrl+F11 key for macro recording and replay.
'Called from inside setkeys, but it's OK to call setkeys from here as we disallow reentry.
'This can also be called from the in-game debug menu.
sub macro_controls ()
	static reentering as bool = NO
	if reentering then exit sub
	reentering = YES
	if record.active then
		stop_recording_input "Recorded macro, CTRL+F11 to play", errInfo
	elseif replay.active then
		show_overlay_message "Ended macro playback early", 2.
		stop_replaying_input
	else
		macro_menu
	end if
	reentering = NO
end sub

'Display a message above everything else; by default doesn't appear in screenshots.
'Intended for use here in allmodex, but pragmaticlly, can be used in Custom too.
'Note that in-game, you should set gam.showtext/gam.showtext_ticks instead.
sub show_overlay_message (msg as string, seconds as double = 3.)
	overlay_message = msg
	overlay_hide_time = timer + seconds
	overlay_replay_display = NO
end sub

function overlay_message_visible () as bool
	return len(overlay_message) > 0 and overlay_hide_time > timer
end function

'Show the overlay for replaying input
private sub show_replay_overlay ()
	overlay_replay_display = YES
end sub

private sub hide_overlays ()
	overlay_message = ""
	overlay_replay_display = NO
end sub

private function ms_to_string (ms as integer) as string
	return seconds2str(cint(ms * 0.001), "%h:%M:%S")
end function

sub toggle_fps_display ()
	overlay_showfps = (overlay_showfps + 1) MOD 3
end sub

' Called every time a frame is drawn.
' skipped: true if this frame was frameskipped.
private sub update_fps_counter (skipped as bool)
	fps_draw_frames += 1
	if not skipped then
		fps_real_frames += 1
	end if
	if timer > fps_time_start + 1 then
		dim nowtime as double = timer
		draw_fps = fps_draw_frames / (nowtime - fps_time_start)
		real_fps = fps_real_frames / (nowtime - fps_time_start)
		fps_time_start = nowtime
		fps_draw_frames = 0
		fps_real_frames = 0
	end if
end sub

'Draw stuff on top of the video page about to be shown; specially those things
'that are included in .gifs/screenshots even without --recordoverlays
'Returns true if something was drawn.
private function draw_allmodex_recordable_overlays (page as integer) as bool
	dim dirty as bool = NO

	if gif_show_mouse then
		with mouse_state
			dim col as integer = uilook(uiSelectedItem + global_tog)
			rectangle .x - 4, .y, 9, 1, col, page
			rectangle .x, .y - 4, 1, 9, col, page
		end with
		dirty = YES
	end if

	if gif_show_keys andalso recordgif.active then
		' Build up two strings describing keypresses, so that modifiers like LShift
		' are sorted to the front.
		' FIXME: due to frameskip some keypresses might not be recorded. Should show for more than 1 tick.
		dim as string modifiers, keys
		with *iif(replay.active, @replay_kb, @real_kb)
			for idx as integer = 0 to ubound(.keybd)
				if .keybd(idx) = 0 then continue for
				dim keyname as string = scancodename(idx)
				select case idx
				case scLeftShift, scRightShift, scLeftAlt, scRightAlt, scLeftCtrl, scRightCtrl
					modifiers &= "+" & scancodename(idx)
				case scShift, scAlt, scUnfilteredAlt, scCtrl, scAnyEnter
					'Ignore these duplicates
				case else
					keys &= "+" & scancodename(idx)
				end select
			next idx
		end with
		dim keysmsg as string = mid(modifiers & keys, 2)  'trim leading + if any
		if len(keysmsg) then
			rectangle pRight, pTop, textwidth(keysmsg) + 2, 10, uilook(uiBackground), page
			edgeprint keysmsg, pRight - 1, pTop, uilook(uiText), page
			dirty = YES
		end if
	end if

	return dirty
end function

'Draw stuff on top of the video page about to be shown.
'Returns true if something was drawn.
private function draw_allmodex_overlays (page as integer) as bool
	if overlays_enabled = NO then return NO

	'show_overlay_message "mouse over:" & gfx_getwindowstate()->mouse_over & " at " & mouse_state.pos

	dim dirty as bool = NO

	if overlay_showfps then
		dim fpsstring as string
		if overlay_showfps = 2 then
			fpsstring = "Draw:" & format(draw_fps, "0.0") & " FPS"
		else
			fpsstring = "Display:" & format(real_fps, "0.0") & " FPS"
		end if
		' Move the FPS a little to the left, because on OSX+gfx_sdl the handle for resizable
		' windows is drawn in the bottom right corner by SDL (not the OS).
		edgeprint fpsstring, pRight - 14, iif(overlay_replay_display, pTop, pBottom), uilook(uiText), page
		dirty = YES
	end if

	if overlay_replay_display then
		overlay_hide_time = 0.  'Hides any other message
		dim repeat_str as string
		if replay.repeat_count > 1 then
			repeat_str = "#" & (1 + replay.repeats_done) & "/" & replay.repeat_count
		end if
		overlay_message = "Pos: " & ms_to_string(replay.play_position_ms) & "/" & ms_to_string(replay.length_ms) & _
		     "  " & rpad(replay.tick & "/" & replay.length_ticks, " ", 9) & repeat_str & _
		     !"\nSpeed: " & rpad(fps_multiplier & "x", " ", 5) & "FPS:" & format(draw_fps, "0.0") & " [F1 for help]"
	elseif overlay_hide_time < timer then
		overlay_message = ""
	end if

	if len(overlay_message) then
		basic_textbox overlay_message, uilook(uiText), page, rBottom + ancBottom - 2, , YES
		dirty = YES
	end if

	return dirty
end function


'==========================================================================================
'                                  Recording and replay
'==========================================================================================


sub start_recording_input (filename as string)
	if replay.active or replay.paused then
		debug "Can't record input because already replaying input!"
		exit sub
	end if
	if isfile(filename) then
		debug "Replacing the input recording that already existed at """ & filename & """"
	end if
	record.constructor()  'Clear data
	if openfile(filename, for_binary + access_write, record.file) then
		stop_recording_input "Couldn't open " & filename
		record.file = -1
		exit sub
	end if
	dim header as string = "OHRRPGCEkeys"
	put #record.file,, header
	dim ohrkey_ver as integer = 4
	put #record.file,, ohrkey_ver
	dim seed as double = TIMER
	RANDOMIZE seed, 3
	put #record.file,, seed
	record.active = YES
	debuginfo "Recording keyboard input to: """ & filename & """"
end sub

sub stop_recording_input (msg as string="", byval errorlevel as ErrorLevelEnum = errError)
	if msg <> "" then
		debugc errorlevel, msg
		show_overlay_message msg
	end if
	if record.active or record.paused then
		close #record.file
		record.active = NO
		record.paused = NO
		debuginfo "STOP recording input"
	end if
end sub

' While recording is paused you can call setkeys without updating the recorded state.
' The keyboard state before pausing is restored when resuming, so it's safe to pause
' and resume recording anywhere.
sub pause_recording_input
	if record.active then
		record.active = NO
		record.paused = YES
		record.last_kb = real_kb
	end if
end sub

sub resume_recording_input
	if record.paused then
		record.active = YES
		record.paused = NO
		real_kb = record.last_kb
	end if
end sub

' Start replaying again from the beginning, used for loop
sub restart_replaying_input ()
	replay.tick = -1
	replay.nexttick = -1
	replay.play_position_ms = 0
	seek replay.file, 1
	load_replay_header()
end sub

sub start_replaying_input (filename as string, num_repeats as integer = 1)
	if record.active or record.paused then
		debug "Can't replay input because already recording input!"
		exit sub
	end if
	replay.constructor()     'Reset
	replay_kb.constructor()  'Reset
	replay.filename = filename
	if openfile(filename, for_binary + access_read, replay.file) then
		stop_replaying_input "Couldn't open " & filename
		replay.file = -1
		exit sub
	end if
	replay.active = YES
	replay.repeat_count = num_repeats
	load_replay_header()
end sub

sub load_replay_header ()
	dim header as string = STRING(12, 0)
	GET #replay.file,, header
	if header <> "OHRRPGCEkeys" then
		stop_replaying_input "No OHRRPGCEkeys header in """ & replay.filename & """"
		exit sub
	end if
	dim ohrkey_ver as integer = -1
	GET #replay.file,, ohrkey_ver
	if ohrkey_ver <> 4 then
		stop_replaying_input "Unknown ohrkey version code " & ohrkey_ver & " in """ & replay.filename & """. Only know how to understand version 4"
		exit sub
	end if
	dim seed as double
	GET #replay.file,, seed
	RANDOMIZE seed, 3
	debuginfo "Replaying keyboard input from: """ & replay.filename & """"
	read_replay_length()
	if replay.repeats_done = 0 then
		show_replay_overlay()
	end if
end sub

sub stop_replaying_input (msg as string="", byval errorlevel as ErrorLevelEnum = errError)
	if msg <> "" then
		debugc errorlevel, msg
		show_overlay_message msg
	end if
	if replay.active or replay.paused then
		close #replay.file
		replay.file = -1
		replay.active = NO
		replay.paused = NO
		debugc errorlevel, "STOP replaying input"
		use_speed_control = YES
	end if
	' Cancel any speedup
	base_fps_multiplier = 1.
end sub

' While replay is paused you can call setkeys without changing the replay state,
' and keyval, etc, return the real state of the keyboard.
' (Safe to try pausing/resuming when not replaying)
sub pause_replaying_input
        ' The replay state is preserved in replay_kb, so pausing and resuming is easy.
	if replay.active then
		replay.active = NO
		replay.paused = YES
	end if
end sub

sub resume_replaying_input
	if replay.paused then
		replay.active = YES
		replay.paused = NO
	end if
end sub

sub record_input_tick ()
	record.tick += 1
	dim presses as ubyte = 0
	dim keys_down as integer = 0
	for i as integer = 0 to scLAST
		if real_kb.keybd(i) <> record.last_kb.keybd(i) then
			presses += 1
		end if
		if real_kb.keybd(i) then keys_down += 1  'must record setkeys_elapsed_ms
	next i
	if presses = 0 and keys_down = 0 and len(real_kb.inputtext) = 0 then exit sub

	dim debugstr as string
	if record.debug then debugstr = "L:" & LOC(record.file) & " T:" & record.tick & " ms:" & real_kb.setkeys_elapsed_ms & " ("

	put #record.file,, record.tick
	put #record.file,, cubyte(real_kb.setkeys_elapsed_ms)
	put #record.file,, presses

	for i as ubyte = 0 to scLAST
		if real_kb.keybd(i) <> record.last_kb.keybd(i) then
			PUT #record.file,, i
			PUT #record.file,, cubyte(real_kb.keybd(i))
			if record.debug then debugstr &= " " & scancodename(i) & "=" & real_kb.keybd(i)
		end if
	next i
	'Currently inputtext is Latin-1, format will need changing in future
	put #record.file,, cubyte(len(real_kb.inputtext))
	put #record.file,, real_kb.inputtext
	if record.debug then
		debugstr &= " )"
		if len(real_kb.inputtext) then debugstr &= " input: '" & real_kb.inputtext & "'"
		debuginfo debugstr
	end if
	record.last_kb = real_kb
end sub

' Scan the replay file to find its length, setting replay.length_ms and replay.length_ticks
' Assumes replay.file is at start of the data stream.
private sub read_replay_length ()
	dim as integer tick, nexttick
	dim as ubyte tick_ms = 55, presses, input_len
	dim initial_pos as integer = LOC(replay.file)
	replay.length_ms = 0

	do
		get #replay.file,, nexttick
		if eof(replay.file) then exit do
		if nexttick < tick then
			visible_debug "Replay corrupt: tick " & replay.nexttick & " occurs after " & tick
			exit do
		end if

		' Assume any skipped ticks are the same length as the next one, seems to give a vastly better
		' estimate than using the previous tick.
		' (This could be way off, some ticks are 0ms or 255+ms)
		get #replay.file,, tick_ms
		replay.length_ms += tick_ms * (nexttick - tick)
		' if (nexttick - tick) > 1 and (tick_ms < 50 or tick_ms > 60) then
		' 	debug "dubious tick_ms estimate " & tick_ms & " at " & tick & " for " & (nexttick - tick) & " ticks"
		' end if

		tick = nexttick
		get #replay.file,, presses
		if presses > scLAST + 1 then
			visible_debug "Replay corrupt: presses=" & presses
			exit do
		end if

		seek #replay.file, 1 + loc(replay.file) + 2 * presses
		GET #replay.file,, input_len
		if input_len then
			seek #replay.file, 1 + loc(replay.file) + input_len
		end if
	loop
	replay.length_ticks = tick
	seek #replay.file, 1 + initial_pos
end sub

sub replay_input_tick ()
	replay.tick += 1
	do
		if EOF(replay.file) then
			replay.repeats_done += 1
			'show_overlay_message "Finished replay " & replay.repeats_done & " of " & replay.repeat_count

			if replay.repeats_done >= replay.repeat_count then
				stop_replaying_input "The end of the playback file was reached.", errInfo
				exit sub
			else
				restart_replaying_input
			end if
		end if

		'Check whether it's time to play the next recorded tick in the replay file
		'(ticks on which nothing happened aren't saved)
		if replay.nexttick = -1 then
			replay.fpos = LOC(replay.file)
			GET #replay.file,, replay.nexttick
			' Grab the next tick_ms already, because for some reason it gives far more accurate .play_position_ms estimation
			dim tick_ms as ubyte
			GET #replay.file,, tick_ms
			replay.next_tick_ms = tick_ms
		end if
		if replay.nexttick < replay.tick then
			debug "input replay late for tick " & replay.nexttick & " (" & replay.nexttick - replay.tick & ")"
		elseif replay.nexttick > replay.tick then
			'debug "saving replay input tick " & replay.nexttick & " until its time has come (+" & replay.nexttick - replay.tick & ")"
			for i as integer = 0 to scLAST
				'Check for a corrupt file
				if replay_kb.keybd(i) then
					' There ought to be a tick in the input file so that we can set setkeys_elapsed_ms correctly
					debug "bad recorded key input: key " & i & " is down, but expected tick " & replay.tick & " is missing"
					exit for
				end if
			next
			' Otherwise, this doesn't matter as it won't be used
			replay_kb.setkeys_elapsed_ms = 1
			' Increment how much we've played so far - not actual play time but at same rate as the .length_ms estimate
			replay.play_position_ms += replay.next_tick_ms
			replay_kb.inputtext = ""
			exit sub
		end if

		replay_kb.setkeys_elapsed_ms = replay.next_tick_ms
		replay.play_position_ms += replay.next_tick_ms

		dim presses as ubyte
		GET #replay.file,, presses
		if presses > scLAST + 1 then
			stop_replaying_input "input replay tick " & replay.nexttick & " has invalid number of keypresses " & presses
			exit sub
		end if

		dim as string info
		if replay.debug then
			info = "L:" & replay.fpos & " T:" & replay.nexttick & " ms:" & replay_kb.setkeys_elapsed_ms & " ("
		end if

		dim key as ubyte
		dim keybits as ubyte
		for i as integer = 1 to presses
			GET #replay.file,, key
			GET #replay.file,, keybits
			replay_kb.keybd(key) = keybits
			if replay.debug then info &= " " & scancodename(key) & "=" & keybits
		next i
		info &= " )"
		dim input_len as ubyte
		GET #replay.file,, input_len
		if input_len then
			'Currently inputtext is Latin-1, format will need changing in future
			replay_kb.inputtext = space(input_len)
			GET #replay.file,, replay_kb.inputtext
			if replay.debug then info &= " input: '" & replay_kb.inputtext & "'"
		else
			replay_kb.inputtext = ""
		end if

		if replay.debug then debuginfo info

		'In case the replay somehow became out of sync, keep looping until we catch up
		'(Probably hopeless though)
		if replay.nexttick = replay.tick then
			replay.nexttick = -1
			exit sub
		end if
		replay.nexttick = -1
	loop
end sub


'==========================================================================================
'                                      Map rendering
'==========================================================================================

function readblock (map as TileMap, byval x as integer, byval y as integer, byval default as integer = 112343211) as integer
	if x < 0 OR x >= map.wide OR y < 0 OR y >= map.high then
		if default <> 112343211 then return default
		debug "illegal readblock call " & x & " " & y
		exit function
	end if
	return map.data[x + y * map.wide]
end function

sub writeblock (map as TileMap, byval x as integer, byval y as integer, byval v as integer)
	if x < 0 OR x >= map.wide OR y < 0 OR y >= map.high then
		debug "illegal writeblock call " & x & " " & y
		exit sub
	end if
	map.data[x + y * map.wide] = v
end sub

'Calculate which tile to display
private function calcblock (tmap as TileMap, byval x as integer, byval y as integer, byval overheadmode as integer, pmapptr as TileMap ptr) as integer
'returns -1 to draw no tile
'overheadmode = 0 : ignore overhead tile bit; draw normally;
'overheadmode = 1 : draw non overhead tiles only (to avoid double draw)
'overheadmode = 2 : draw overhead tiles only
	dim block as integer

	'check bounds
	if bordertile = -1 then
		'wrap
		while y < 0
			y = y + tmap.high
		wend
		while y >= tmap.high
			y = y - tmap.high
		wend
		while x < 0
			x = x + tmap.wide
		wend
		while x >= tmap.wide
			x = x - tmap.wide
		wend
	else
		if (y < 0) or (y >= tmap.high) or (x < 0) or (x >= tmap.wide) then
			if tmap.layernum = 0 and overheadmode <= 1 then
				'only draw the border tile once!
				return bordertile
			else
				return -1
			end if
		end if
	end if

	block = readblock(tmap, x, y)

	if block = 0 and tmap.layernum > 0 then  'This could be an argument, maybe we could get rid of layernum
		return -1
	end if

	if overheadmode > 0 then
		if pmapptr = NULL then
			debugc errPromptBug, "calcblock: overheadmode but passmap ptr is NULL"
			block = -1
		elseif x >= pmapptr->wide or y >= pmapptr->high then
			'Impossible if the passmap is the same size
			if overheadmode = 2 then block = -1
		elseif ((readblock(*pmapptr, x, y) and passOverhead) <> 0) xor (overheadmode = 2) then
			block = -1
		end if
	end if

	return block
end function

'Given a tile number, possibly animated, translate it to the static tile to display
function translate_animated_tile(todraw as integer) as integer
	if todraw >= 208 then
		return (todraw - 48 + anim2) mod 160
	elseif todraw >= 160 then
		return (todraw + anim1) mod 160
	else
		return todraw
	end if
end function

sub drawmap (tmap as TileMap, byval x as integer, byval y as integer, byval tileset as TilesetData ptr, byval p as integer, byval trans as bool = NO, byval overheadmode as integer = 0, byval pmapptr as TileMap ptr = NULL, byval ystart as integer = 0, byval yheight as integer = -1)
	'overrides setanim
	anim1 = tileset->tastuf(0) + tileset->anim(0).cycle
	anim2 = tileset->tastuf(20) + tileset->anim(1).cycle
	drawmap tmap, x, y, tileset->spr, p, trans, overheadmode, pmapptr, ystart, yheight
end sub

sub drawmap (tmap as TileMap, byval x as integer, byval y as integer, byval tilesetsprite as Frame ptr, byval p as integer, byval trans as bool = NO, byval overheadmode as integer = 0, byval pmapptr as TileMap ptr = NULL, byval ystart as integer = 0, byval yheight as integer = -1, byval largetileset as bool = NO)
'ystart is the distance from the top to start drawing, yheight the number of lines. yheight=-1 indicates extend to bottom of screen
'There are no options in the X direction because they've never been used, and I don't forsee them being (can use Frames or slices instead)
	dim mapview as Frame ptr
	mapview = frame_new_view(vpages(p), 0, ystart, vpages(p)->w, iif(yheight = -1, vpages(p)->h, yheight))
	drawmap tmap, x, y, tilesetsprite, mapview, trans, overheadmode, pmapptr, largetileset
	frame_unload @mapview
end sub

sub drawmap (tmap as TileMap, byval x as integer, byval y as integer, byval tilesetsprite as Frame ptr, byval dest as Frame ptr, byval trans as bool = NO, byval overheadmode as integer = 0, byval pmapptr as TileMap ptr = NULL, byval largetileset as bool = NO)
'This version of drawmap paints over the entire dest Frame given to it.
'x and y are the camera position at the top left corner of the Frame, not
'the position at which the top left of the map is drawn: this is the OPPOSITE
'to all other drawing commands!
'overheadmode = 0 : draw all tiles normally
'overheadmode = 1 : draw non overhead tiles only (to avoid double draw)
'overheadmode = 2 : draw overhead tiles only
'largetileset : A hack which disables tile animation, instead using tilesets with 256 tiles

	dim sptr as ubyte ptr
	dim plane as integer

	dim ypos as integer
	dim xpos as integer
	dim xstart as integer
	dim yoff as integer
	dim xoff as integer
	dim calc as integer
	dim ty as integer
	dim tx as integer
	dim todraw as integer
	dim tileframe as frame

	if clippedframe <> dest then
		setclip , , , , dest
	end if

	'copied from the asm
	ypos = y \ 20
	calc = y mod 20
	if calc < 0 then	'adjust for negative coords
		calc = calc + 20
		ypos = ypos - 1
	end if
	yoff = -calc

	xpos = x \ 20
	calc = x mod 20
	if calc < 0 then
		calc = calc + 20
		xpos = xpos - 1
	end if
	xoff = -calc
	xstart = xpos

	tileframe.w = 20
	tileframe.h = 20
	tileframe.pitch = 20

	ty = yoff
	while ty < dest->h
		tx = xoff
		xpos = xstart
		while tx < dest->w
			todraw = calcblock(tmap, xpos, ypos, overheadmode, pmapptr)
			if largetileset = NO then
				todraw = translate_animated_tile(todraw)
			end if

			'get the tile
			if (todraw >= 0) then
				tileframe.image = tilesetsprite->image + todraw * 20 * 20
				if tilesetsprite->mask then 'just in case it happens some day
					tileframe.mask = tilesetsprite->mask + todraw * 20 * 20
				else
					tileframe.mask = NULL
				end if

				'draw it on the map
				frame_draw_internal(@tileframe, intpal(), , tx, ty, , trans, dest)
			end if

			tx = tx + 20
			xpos = xpos + 1
		wend
		ty = ty + 20
		ypos = ypos + 1
	wend
end sub

sub setanim (byval cycle1 as integer, byval cycle2 as integer)
	anim1 = cycle1
	anim2 = cycle2
end sub

sub setoutside (byval defaulttile as integer)
	bordertile = defaulttile
end sub

' Draws all map layers at a single tile coordinate. Used for drawing the minimap.
' Respects setoutside. Changes the setanim (current tileset animation) state.
sub draw_layers_at_tile(composed_tile as Frame ptr, tiles() as TileMap, tilesets() as TilesetData ptr, tx as integer, ty as integer, pmapptr as TileMap ptr = NULL)
	for idx as integer = 0 to ubound(tiles)
		'It's possible that layer <> idx if for example drawing a minimap of a single map layer
		dim layer as integer = tiles(idx).layernum
		with *tilesets(idx)
			setanim .tastuf(0) + .anim(0).cycle, .tastuf(20) + .anim(1).cycle

			dim todraw as integer = calcblock(tiles(idx), tx, ty, 0, 0)
			if todraw = -1 then continue for
			todraw = translate_animated_tile(todraw)

			frame_draw .spr, , 0, -todraw * 20, 1, (layer > 0), composed_tile

			if layer = 0 andalso pmapptr andalso (readblock(*pmapptr, tx, ty) and passOverhead) then
				' If an overhead tile, return just the layer 0 tile
				exit for
			end if
		end with
	next
end sub


'==========================================================================================
'                                 Old graphics API wrappers
'==========================================================================================


sub drawsprite (pic() as integer, byval picoff as integer, pal() as integer, byval po as integer, byval x as integer, byval y as integer, byval page as integer, byval trans as bool = YES)
'draw sprite from pic(picoff) onto page using pal() starting at po
	drawspritex(pic(), picoff, pal(), po, x, y, page, 1, trans)
end sub

sub bigsprite (pic() as integer, pal() as integer, byval p as integer, byval x as integer, byval y as integer, byval page as integer, byval trans as bool = YES)
	drawspritex(pic(), 0, pal(), p, x, y, page, 2, trans)
end sub

sub hugesprite (pic() as integer, pal() as integer, byval p as integer, byval x as integer, byval y as integer, byval page as integer, byval trans as bool = YES)
	drawspritex(pic(), 0, pal(), p, x, y, page, 4, trans)
end sub

'Create a palette from a record in .PAL
function Palette16_new_from_buffer(pal() as integer, byval po as integer = 0) as Palette16 ptr
	dim ret as Palette16 ptr = Palette16_new()
	dim word as integer

	for i as integer = 0 to 15
		'palettes are interleaved like everything else
		word = pal((po + i) \ 2)	' get color from palette
		if (po + i) mod 2 = 1 then
			ret->col(i) = (word and &hff00) shr 8
		else
			ret->col(i) = word and &hff
		end if
	next
	return ret
end function

'Convert a (deprecated) pixel array representation of a 4 bit sprite to a Frame
function frame_new_from_buffer(pic() as integer, byval picoff as integer = 0) as Frame ptr
	dim sw as integer
	dim sh as integer
	dim hspr as frame ptr
	dim dspr as ubyte ptr
	dim nib as integer
	dim i as integer
	dim spix as integer  ' 2-byte word read from source
	dim row as integer

	sw = pic(picoff)
	sh = pic(picoff+1)
	picoff = picoff + 2

	hspr = frame_new(sw, sh)
	dspr = hspr->image

	'now do the pixels
	'pixels are in columns, so this might not be the best way to do it
	'maybe just drawing straight to the screen would be easier
	nib = 0
	row = 0
	for i = 0 to (sw * sh) - 1
		select case nib			' 2 bytes = 4 nibbles in each int
			case 0
				spix = (pic(picoff) and &h00f0) shr 4
			case 1
				spix = (pic(picoff) and &h000f) shr 0
			case 2
				spix = (pic(picoff) and &hf000) shr 12
			case 3
				spix = (pic(picoff) and &h0f00) shr 8
				picoff = picoff + 1
		end select
		*dspr = spix				' set image pixel
		dspr = dspr + sw
		row = row + 1
		if (row >= sh) then	'ugh
			dspr = dspr - (sw * sh)
			dspr = dspr + 1
			row = 0
		end if
		nib = nib + 1
		nib = nib and 3
	next
	return hspr
end function

sub drawspritex (pic() as integer, byval picoff as integer, pal as Palette16 ptr, byval x as integer, byval y as integer, byval page as integer, byval scale as integer = 1, byval trans as bool = YES)
'draw sprite scaled, used for drawsprite(x1), bigsprite(x2) and hugesprite(x4)
	if clippedframe <> vpages(page) then
		setclip , , , , vpages(page)
	end if

	'convert the buffer into a Frame
	dim hspr as frame ptr
	hspr = frame_new_from_buffer(pic(), picoff)

	'now draw the image
	frame_draw(hspr, pal, x, y, scale, trans, page)
	'what a waste
	frame_unload(@hspr)
end sub

' Temp overload whichs exists to help detangle the sprite editor from its bad old ways
sub drawspritex (pic() as integer, byval picoff as integer, pal() as integer, byval po as integer, byval x as integer, byval y as integer, byval page as integer, byval scale as integer = 1, byval trans as bool = YES)
'draw sprite scaled, used for drawsprite(x1), bigsprite(x2) and hugesprite(x4)
	dim hpal as Palette16 ptr
	hpal = Palette16_new_from_buffer(pal(), po)
	drawspritex pic(), picoff, hpal, x, y, page, scale, trans
	Palette16_unload @hpal
end sub

sub wardsprite (pic() as integer, byval picoff as integer, pal() as integer, byval po as integer, byval x as integer, byval y as integer, byval page as integer, byval trans as bool = YES)
'this just draws the sprite mirrored
'the coords are still top-left
	dim sw as integer
	dim sh as integer
	dim hspr as frame ptr
	dim dspr as ubyte ptr
	dim nib as integer
	dim i as integer
	dim spix as integer  ' 2-byte word read from source
	dim pix as integer
	dim row as integer

	if clippedframe <> vpages(page) then
		setclip , , , , vpages(page)
	end if

	sw = pic(picoff)
	sh = pic(picoff+1)
	picoff = picoff + 2

	hspr = frame_new(sw, sh)
	dspr = hspr->image
	dspr = dspr + sw - 1 'jump to last column

	'now do the pixels
	'pixels are in columns, so this might not be the best way to do it
	'maybe just drawing straight to the screen would be easier
	nib = 0
	row = 0
	for i = 0 to (sw * sh) - 1
		select case nib			' 2 bytes = 4 nibbles in each int
			case 0
				spix = (pic(picoff) and &hf0) shr 4
			case 1
				spix = (pic(picoff) and &h0f) shr 0
			case 2
				spix = (pic(picoff) and &hf000) shr 12
			case 3
				spix = (pic(picoff) and &h0f00) shr 8
				picoff = picoff + 1
		end select
		if spix = 0 and trans then
			pix = 0					' transparent
		else
			'palettes are interleaved like everything else
			pix = pal((po + spix) \ 2)	' get color from palette
			if (po + spix) mod 2 = 1 then
				pix = (pix and &hff00) shr 8
			else
				pix = pix and &hff
			end if
		end if
		*dspr = pix				' set image pixel
		dspr = dspr + sw
		row = row + 1
		if (row >= sh) then	'ugh
			dspr = dspr - (sw * sh)
			dspr = dspr - 1		' right to left for wardsprite
			row = 0
		end if
		nib = nib + 1
		nib = nib and 3
	next

	'now draw the image
	frame_draw(hspr, NULL, x, y, , trans, page)

	frame_unload(@hspr)
end sub

sub stosprite (pic() as integer, byval picoff as integer, byval x as integer, byval y as integer, byval page as integer)
'This is the opposite of loadsprite, ie store raw sprite data in screen p
'starting at x, y.
	dim i as integer
	dim poff as integer
	dim toggle as integer
	dim sbytes as integer
	dim h as integer
	dim w as integer

	if clippedframe <> vpages(page) then
		setclip , , , , vpages(page)
	end if
	CHECK_FRAME_8BIT(vpages(page))

	poff = picoff
	w = pic(poff)
	h = pic(poff + 1)
	poff += 2
	sbytes = ((w * h) + 1) \ 2	'only 4 bits per pixel

	y += x \ 320
	x = x mod 320

	'copy from passed int buffer, with 2 bytes per int as usual
	toggle = 0
	for i = 0 to sbytes - 1
		if toggle = 0 then
			PAGEPIXEL(x, y, page) = pic(poff) and &hff
			toggle = 1
		else
			PAGEPIXEL(x, y, page) = (pic(poff) and &hff00) shr 8
			toggle = 0
			poff += 1
		end if
		x += 1
		if x = 320 then
			y += 1
			x = 0
		end if
	next

end sub

sub loadsprite (pic() as integer, byval picoff as integer, byval x as integer, byval y as integer, byval w as integer, byval h as integer, byval page as integer)
'reads sprite from given page into pic(), starting at picoff
	dim i as integer
	dim poff as integer
	dim toggle as integer
	dim sbytes as integer
	dim temp as integer

	if clippedframe <> vpages(page) then
		setclip , , , , vpages(page)
	end if
	CHECK_FRAME_8BIT(vpages(page))

	sbytes = ((w * h) + 1) \ 2	'only 4 bits per pixel

	y += x \ 320
	x = x mod 320

	'copy to passed int buffer, with 2 bytes per int as usual
	toggle = 0
	poff = picoff
	pic(poff) = w			'these are 4byte ints, not compat w. orig.
	pic(poff+1) = h
	poff += 2
	for i = 0 to sbytes - 1
		temp = PAGEPIXEL(x, y, page)
		if toggle = 0 then
			pic(poff) = temp
		else
			pic(poff) = pic(poff) or (temp shl 8)
			poff += 1
		end if
		toggle xor= 1
		x += 1
		if x = 320 then
			y += 1
			x = 0
		end if
	next

end sub

sub getsprite (pic() as integer, byval picoff as integer, byval x as integer, byval y as integer, byval w as integer, byval h as integer, byval page as integer)
'This reads a rectangular region of a screen page into sprite buffer array pic() at picoff
'It assumes that all the pixels it encounters will be colors 0-15 of the master palette
'even though those colors will certainly be mapped to some other 16 color palette when drawn
	dim as ubyte ptr sbase, sptr
	dim nyb as integer = 0
	dim p as integer = 0
	dim as integer sw, sh

	CHECK_FRAME_8BIT(vpages(page))

	'store width and height
	p = picoff
	pic(p) = w
	p += 1
	pic(p) = h
	p += 1

	'find start of image
	sbase = vpages(page)->image + (vpages(page)->pitch * y) + x

	'pixels are stored in columns for the sprites (argh)
	for sh = 0 to small(w, vpages(page)->w)  - 1
		sptr = sbase
		for sw = 0 to small(h, vpages(page)->h) - 1
			select case nyb
				case 0
					pic(p) = (*sptr and &h0f) shl 4
				case 1
					pic(p) = pic(p) or ((*sptr and &h0f) shl 0)
				case 2
					pic(p) = pic(p) or ((*sptr and &h0f) shl 12)
				case 3
					pic(p) = pic(p) or (*sptr and &h0f) shl 8
					p += 1
			end select
			sptr += vpages(page)->pitch
			nyb = (nyb + 1) and 3
		next
		sbase = sbase + 1 'next col
	next

end sub

'Convenience wrapper around getsprite to grab an entire Frame instead of a sub-rectangle of a page
sub frame_to_buffer(spr as Frame ptr, pic() as integer)
	dim page as integer = registerpage(spr)
	getsprite pic(), 0, 0, 0, spr->w, spr->h, page
	freepage page
end sub


'==========================================================================================
'                                     Old allmodex IO
'==========================================================================================
' These are specifically for reading/writing files. The other obsolete
' graphics stuff is above.

sub storemxs (fil as string, byval record as integer, byval fr as Frame ptr)
'saves a screen page to a file. Doesn't support non-320x200 pages
	dim f as integer
	dim as integer x, y
	dim sptr as ubyte ptr
	dim plane as integer

	CHECK_FRAME_8BIT(fr)

	if openfile(fil, for_binary + access_read_write, f) then exit sub

	'skip to index
	seek #f, (record*64000) + 1 'will this work with write access?

	'modex format, 4 planes
	for plane = 0 to 3
		for y = 0 to 199
			sptr = fr->image + fr->pitch * y + plane

			for x = 0 to (80 - 1) '1/4 of a row
				put #f, , *sptr
				sptr = sptr + 4
			next
		next
	next

	close #f
end sub

'For compatibility: load into an existing Frame.
'NOTE: Don't use this in new code. It bypasses the cache. Use frame_load
sub loadmxs (filen as string, record as integer, dest as Frame ptr)
	dim temp as Frame ptr
	temp = frame_load_mxs(filen, record)
	frame_clear dest
	if temp then
		frame_draw temp, , 0, 0, , NO, dest
		frame_unload @temp
	end if
end sub

'Loads a 320x200 mode X format page from a file.
'This should probably only be called directly when loading from file outside an .rpg,
'otherwise use frame_load.
function frame_load_mxs (filen as string, record as integer) as Frame ptr
	dim starttime as double = timer
	dim fh as integer
	dim as integer x, y
	dim sptr as ubyte ptr
	dim plane as integer
	dim dest as Frame ptr

	'Return blank Frame on failure
	dest = frame_new(320, 200, , YES)

	if record < 0 then
		debugc errBug, "frame_load_mxs: attempted to read a negative record number " & record
		return dest
	end if
	if openfile(filen, for_binary + access_read, fh) then
		debugc errError, "frame_load_mxs: Couldn't open " & filen
		return dest
	end if

	if lof(fh) < (record + 1) * 64000 then
		debugc errError, "frame_load_mxs: wanted page " & record & "; " & filen & " is only " & lof(fh) & " bytes"
		close #fh
		return dest
	end if

	'skip to index
	seek #fh, (record*64000) + 1

	dim quarter_row(79) as ubyte

	'modex format, 4 planes
	for plane = 0 to 3
		for y = 0 to 200 - 1
			sptr = dest->image + dest->pitch * y + plane

			'1/4 of a row
			get #fh, , quarter_row()
			for x = 0 to 80 - 1
				sptr[x * 4] = quarter_row(x)
			next
		next
	next

	close #fh
	debug_if_slow(starttime, 0.1, filen)
	return dest
end function


'==========================================================================================
'                                   Graphics primitives
'==========================================================================================


'No clipping!!
sub putpixel (byval spr as Frame ptr, byval x as integer, byval y as integer, byval c as integer)
	if x < 0 orelse x >= spr->w orelse y < 0 orelse y >= spr->h then
		exit sub
	end if
	CHECK_FRAME_8BIT(spr)
	FRAMEPIXEL(x, y, spr) = c
end sub

sub putpixel (byval x as integer, byval y as integer, byval c as integer, byval p as integer)
	if clippedframe <> vpages(p) then
		setclip , , , , vpages(p)
	end if
	CHECK_FRAME_8BIT(vpages(p))

	if POINT_CLIPPED(x, y) then
		'debug "attempt to putpixel off-screen " & x & "," & y & "=" & c & " on page " & p
		exit sub
	end if

	PAGEPIXEL(x, y, p) = c
end sub

function readpixel (byval spr as Frame ptr, byval x as integer, byval y as integer) as integer
	if x < 0 orelse x >= spr->w orelse y < 0 orelse y >= spr->h then
		return -1
	end if
	CHECK_FRAME_8BIT(spr, 0)

	return FRAMEPIXEL(x, y, spr)
end function

function readpixel (byval x as integer, byval y as integer, byval p as integer) as integer
	if clippedframe <> vpages(p) then
		setclip , , , , vpages(p)
	end if
	CHECK_FRAME_8BIT(vpages(p), 0)

	if POINT_CLIPPED(x, y) then
		debug "attempt to readpixel off-screen " & x & "," & y & " on page " & p
		return -1
	end if
	return PAGEPIXEL(x, y, p)
end function

sub drawbox (x as RelPos, y as RelPos, w as RelPos, h as RelPos, col as integer, thickness as integer = 1, p as integer)
	drawbox vpages(p), x, y, w, h, col, thickness
end sub

'Draw a hollow box, with given edge thickness
sub drawbox (dest as Frame ptr, x as RelPos, y as RelPos, w as RelPos, h as RelPos, col as integer, thickness as integer = 1)
	w = relative_pos(w, dest->w)
	h = relative_pos(h, dest->h)

	if w < 0 then x = x + w + 1: w = -w
	if h < 0 then y = y + h + 1: h = -h

	if w = 0 or h = 0 then exit sub

	x = relative_pos(x, dest->w, w)
	y = relative_pos(y, dest->h, h)

	dim as integer thickx = small(thickness, w), thicky = small(thickness, h)

	rectangle dest, x, y, w, thicky, col
	IF h > thicky THEN
		rectangle dest, x, y + h - thicky, w, thicky, col
	end IF
	rectangle dest, x, y, thickx, h, col
	IF w > thickx THEN
		rectangle dest, x + w - thickx, y, thickx, h, col
	end IF
end sub

' This function is slightly different from drawbox/rectangle, in that draws boxes with
' width/height 0 as width/height 1 instead of not at all.
' color is the main highlight color; if -1, use default
' FIXME: this function doesn't respect clipping!
sub drawants(dest as Frame ptr, x as RelPos, y as RelPos, wide as RelPos, high as RelPos, color as integer = -1)
	if color = -1 then color = uilook(uiText)

	' Decode relative positions/sizes to absolute
	wide = relative_pos(wide, dest->w)
	high = relative_pos(high, dest->h)
	x = relative_pos(x, dest->w, wide)
	y = relative_pos(y, dest->h, high)

	if wide < 0 then x = x + wide + 1: wide = -wide
	if high < 0 then y = y + high + 1: high = -high

	'if wide <= 0 or high <= 0 then exit sub

	dim col as integer
	'--Draw verticals
	for idx as integer = 0 to large(high - 1, 0)
		select case (idx + x + y + tickcount) mod 3
			case 0: continue for
			case 1: col = color
			case 2: col = uilook(uiBackground)
		end select
		putpixel dest, x, y + idx, col
		if wide > 0 then
			putpixel dest, x + wide - 1, y + idx, col
		end if
	next idx
	'--Draw horizontals
	for idx as integer = 0 to large(wide - 1, 0)
		select case (idx + x + y + tickcount) mod 3
			case 0: continue for
			case 1: col = color
			case 2: col = uilook(uiBackground)
		end select
		putpixel dest, x + idx, y, col
		if high > 0 then
			putpixel dest, x + idx, y + high - 1, col
		end if
	next idx
end sub

sub rectangle (x as RelPos, y as RelPos, w as RelPos, h as RelPos, c as integer, p as integer)
	rectangle vpages(p), x, y, w, h, c
end sub

sub rectangle (fr as Frame Ptr, x as RelPos, y as RelPos, w as RelPos, h as RelPos, c as integer)
	if clippedframe <> fr then
		setclip , , , , fr
	end if

	' Decode relative positions/sizes to absolute
	w = relative_pos(w, fr->w)
	h = relative_pos(h, fr->h)
	x = relative_pos(x, fr->w, w)
	y = relative_pos(y, fr->h, h)

	if w < 0 then x = x + w + 1: w = -w
	if h < 0 then y = y + h + 1: h = -h

	'clip
	if x + w > clipr then w = (clipr - x) + 1
	if y + h > clipb then h = (clipb - y) + 1
	if x < clipl then w -= (clipl - x) : x = clipl
	if y < clipt then h -= (clipt - y) : y = clipt

	if w <= 0 or h <= 0 then exit sub

	if fr->surf then
		dim rect as SurfaceRect = (x, y, x + w - 1, y + h - 1)
		dim col as uint32 = c
		if fr->surf->format = SF_32bit then
			col = intpal(c).col
		end if
		gfx_surfaceFill(col, @rect, fr->surf)
	else
		dim sptr as ubyte ptr = fr->image + (y * fr->pitch) + x
		while h > 0
			memset(sptr, c, w)
			sptr += fr->pitch
			h -= 1
		wend
	end if
end sub

sub fuzzyrect (x as RelPos, y as RelPos, w as RelPos = rWidth, h as RelPos = rHeight, c as integer, p as integer, fuzzfactor as integer = 50)
	fuzzyrect vpages(p), x, y, w, h, c, fuzzfactor
end sub

sub fuzzyrect (fr as Frame Ptr, x as RelPos, y as RelPos, w as RelPos = rWidth, h as RelPos = rHeight, c as integer, fuzzfactor as integer = 50)
	'How many magic constants could you wish for?
	'These were half generated via magic formulas, and half hand picked (with magic criteria)
	static grain_table(50) as integer = {_
	                    50, 46, 42, 38, 38, 40, 41, 39, 26, 38, 30, 36, _
	                    42, 31, 39, 38, 41, 26, 27, 28, 40, 35, 35, 31, _
	                    39, 50, 41, 30, 29, 28, 45, 37, 24, 43, 23, 42, _
	                    21, 28, 11, 16, 20, 22, 18, 17, 19, 32, 17, 16, _
	                    15, 14, 50}

	if clippedframe <> fr then
		setclip , , , , fr
	end if
	CHECK_FRAME_8BIT(fr)

	fuzzfactor = bound(fuzzfactor, 1, 99)

	' Decode relative positions/sizes to absolute
	w = relative_pos(w, fr->w)
	h = relative_pos(h, fr->h)
	x = relative_pos(x, fr->w, w)
	y = relative_pos(y, fr->h, h)

	dim grain as integer
	dim r as integer = 0
	dim startr as integer = 0

	if fuzzfactor <= 50 then grain = grain_table(fuzzfactor) else grain = grain_table(100 - fuzzfactor)
	'if w = 99 then grain = h mod 100  'for hand picking

	if w < 0 then x = x + w + 1: w = -w
	if h < 0 then y = y + h + 1: h = -h

	'clip
	if x + w > clipr then w = (clipr - x) + 1
	if y + h > clipb then h = (clipb - y) + 1
	if x < clipl then
		startr += (clipl - x) * fuzzfactor
		w -= (clipl - x)
		x = clipl
	end if
	if y < clipt then
		startr += (clipt - y) * grain
		h -= (clipt - y)
		y = clipt
	end if

	if w <= 0 or h <= 0 then exit sub

	dim sptr as ubyte ptr = fr->image + (y * fr->pitch) + x
	while h > 0
		startr = (startr + grain) mod 100
		r = startr
		for i as integer = 0 to w-1
			r += fuzzfactor
			if r >= 100 then
				sptr[i] = c
				r -= 100
			end if
		next
		h -= 1
		sptr += fr->pitch
	wend
end sub

'Draw either a rectangle or a scrolling chequer pattern.
'bgcolor is either between 0 and 255 (a colour), bgChequerScroll (a scrolling chequered
'background), or bgChequer (a non-scrolling chequered background)
'chequer_scroll is a counter variable which the calling function should increment once per tick.
'(If chequer_scroll isn't provided, than bgChequerScroll acts like bgChequer.)
'wide and high default to the whole dest Frame.
sub draw_background (dest as Frame ptr, bgcolor as bgType = bgChequerScroll, byref chequer_scroll as integer = 0, x as RelPos = 0, y as RelPos = 0, wide as RelPos = rWidth, high as RelPos = rHeight)
	const zoom = 3  'Chequer pattern zoom, fixed
	const rate = 4  'ticks per pixel scrolled, fixed
	'static chequer_scroll as integer
	chequer_scroll = POSMOD(chequer_scroll, (zoom * rate * 2))

	wide = relative_pos(wide, dest->w)
	high = relative_pos(high, dest->h)
	x = relative_pos(x, dest->w, wide)
	y = relative_pos(y, dest->h, high)

	if bgcolor >= 0 then
		rectangle dest, x, y, wide, high, bgcolor
	else
		dim bg_chequer as Frame Ptr
		bg_chequer = frame_new(wide / zoom + 2, high / zoom + 2)
		frame_clear bg_chequer, uilook(uiBackground)
		fuzzyrect bg_chequer, 0, 0, bg_chequer->w, bg_chequer->h, uilook(uiDisabledItem)
		dim offset as integer = 0
		if bgcolor = -1 then offset = chequer_scroll \ rate
		dim oldclip as ClipState
		saveclip oldclip
		shrinkclip x, y, x + wide - 1, y + high - 1, dest
		frame_draw bg_chequer, NULL, x - offset, y - offset, zoom, NO, dest
		loadclip oldclip
		frame_unload @bg_chequer
	end if
end sub

sub drawline (byval x1 as integer, byval y1 as integer, byval x2 as integer, byval y2 as integer, byval c as integer, byval p as integer)
	drawline vpages(p), x1, y1, x2, y2, c
end sub

sub drawline (byval dest as Frame ptr, byval x1 as integer, byval y1 as integer, byval x2 as integer, byval y2 as integer, byval c as integer)
'uses Bresenham's run-length slice algorithm
	dim as integer xdiff,ydiff
	dim as integer xdirection       'direction of X travel from top to bottom point (1 or -1)
	dim as integer minlength        'minimum length of a line strip
	dim as integer startLength      'length of start strip (approx half 'minLength' to balance line)
	dim as integer runLength        'current run-length to be used (minLength or minLength+1)
	dim as integer endLength        'length of end of line strip (usually same as startLength)

	dim as integer instep           'xdirection or 320 (inner loop)
	dim as integer outstep          'xdirection or 320 (outer loop)
	dim as integer shortaxis        'outer loop control
	dim as integer longaxis

	dim as integer errorterm        'when to draw an extra pixel
	dim as integer erroradd         'add to errorTerm for each strip drawn
	dim as integer errorsub         'subtract from errorterm when triggered

	dim sptr as ubyte ptr

'Macro to simplify code
#macro DRAW_SLICE(a)
	for i as integer = 0 to a-1
		*sptr = c
		sptr += instep
	next
#endmacro

	if clippedframe <> dest then
		setclip , , , , dest
	end if
	CHECK_FRAME_8BIT(dest)

	if POINT_CLIPPED(x1, y1) orelse POINT_CLIPPED(x2, y2) then
		debug "drawline: outside clipping"
		exit sub
	end if

	if y1 > y2 then
		'swap ends, we only draw downwards
		swap y1, y2
		swap x1, x2
	end if

	'point to start
	sptr = dest->image + (y1 * dest->pitch) + x1

	xdiff = x2 - x1
	ydiff = y2 - y1

	if xDiff < 0 then
		'right to left
		xdiff = -xdiff
		xdirection = -1
	else
		xdirection = 1
	end if

	'special case for vertical
	if xdiff = 0 then
		instep = dest->pitch
		DRAW_SLICE(ydiff+1)
		exit sub
	end if

	'and for horizontal
	if ydiff = 0 then
		instep = xdirection
		DRAW_SLICE(xdiff+1)
		exit sub
	end if

	'and also for pure diagonals
	if xdiff = ydiff then
		instep = dest->pitch + xdirection
		DRAW_SLICE(ydiff+1)
		exit sub
	end if

	'now the actual bresenham
	if xdiff > ydiff then
		longaxis = xdiff
		shortaxis = ydiff

		instep = xdirection
		outstep = dest->pitch
	else
		'other way round, draw vertical slices
		longaxis = ydiff
		shortaxis = xdiff

		instep = dest->pitch
		outstep = xdirection
	end if

	'calculate stuff
	minlength = longaxis \ shortaxis
	erroradd = (longaxis mod shortaxis) * 2
	errorsub = shortaxis * 2

	'errorTerm must be initialized properly since first pixel
	'is about in the center of a strip ... not the start
	errorterm = (erroradd \ 2) - errorsub

	startLength = (minLength \ 2) + 1
	endLength = startlength 'half +1 of normal strip length

	'If the minimum strip length is even
	if (minLength and 1) <> 0 then
		errorterm += shortaxis 'adjust errorTerm
	else
		'If the line had no remainder (x&yDiff divided evenly)
		if erroradd = 0 then
			startLength -= 1 'leave out extra start pixel
		end if
	end if

	'draw the start strip
	DRAW_SLICE(startlength)
	sptr += outstep

	'draw the middle strips
	for j as integer = 1 to shortaxis - 1
		runLength = minLength
		errorTerm += erroradd

		if errorTerm > 0 then
			errorTerm -= errorsub
			runLength += 1
		end if

		DRAW_SLICE(runlength)
		sptr += outstep
	next

	DRAW_SLICE(endlength)
end sub

sub paintat (byval dest as Frame ptr, byval x as integer, byval y as integer, byval c as integer)
'a floodfill.
	dim tcol as integer
	dim queue as XYPair_node ptr = null
	dim tail as XYPair_node ptr = null
	dim as integer w, e		'x coords west and east
	dim i as integer
	dim tnode as XYPair_node ptr = null

	if clippedframe <> dest then
		setclip , , , , dest
	end if
	CHECK_FRAME_8BIT(dest)

	if POINT_CLIPPED(x, y) then exit sub

	tcol = readpixel(dest, x, y)	'get target colour

	'prevent infinite loop if you fill with the same colour
	if tcol = c then exit sub

	queue = callocate(sizeof(XYPair_node))
	queue->x = x
	queue->y = y
	queue->nextnode = null
	tail = queue

	'we only let coordinates within the clip bounds get onto the queue, so there's no need to check them

	do
		if FRAMEPIXEL(queue->x, queue->y, dest) = tcol then
			FRAMEPIXEL(queue->x, queue->y, dest) = c
			w = queue->x
			e = queue->x
			'find western limit
			while w > clipl and FRAMEPIXEL(w-1, queue->y, dest) = tcol
				w -= 1
				FRAMEPIXEL(w, queue->y, dest) = c
			wend
			'find eastern limit
			while e < clipr and FRAMEPIXEL(e+1, queue->y, dest) = tcol
				e += 1
				FRAMEPIXEL(e, queue->y, dest) = c
			wend
			'add bordering XYPair_nodes
			for i = w to e
				if queue->y > clipt then
					'north
					if FRAMEPIXEL(i, queue->y-1, dest) = tcol then
						tail->nextnode = callocate(sizeof(XYPair_node))
						tail = tail->nextnode
						tail->x = i
						tail->y = queue->y-1
						tail->nextnode = null
					end if
				end if
				if queue->y < clipb then
					'south
					if FRAMEPIXEL(i, queue->y+1, dest) = tcol then
						tail->nextnode = callocate(sizeof(XYPair_node))
						tail = tail->nextnode
						tail->x = i
						tail->y = queue->y+1
						tail->nextnode = null
					end if
				end if
			next
		end if

		'advance queue pointer, and delete behind us
		tnode = queue
		queue = queue->nextnode
		deallocate(tnode)

	loop while queue <> null
	'should only exit when queue has caught up with tail

end sub

sub ellipse (byval fr as Frame ptr, byval x as double, byval y as double, byval radius as double, byval col as integer, byval fillcol as integer, byval semiminor as double = 0.0, byval angle as double = 0.0)
'radius is the semimajor axis if the ellipse is not a circle
'angle is the angle of the semimajor axis to the x axis, in radians counter-clockwise

	if clippedframe <> fr then
		setclip , , , , fr
	end if
	CHECK_FRAME_8BIT(fr)

	'x,y is the pixel to centre the ellipse at - that is, the centre of that pixel, so add half a pixel to
	'radius to put the perimeter halfway between two pixels
	x += 0.5
	y += 0.5
	radius += 0.5
	if semiminor = 0.0 then
		semiminor = radius
	else
		semiminor += 0.5
	end if

	dim as double ypart
	ypart = fmod(y, 1.0) - 0.5  'Here we add in the fact that we test for intercepts with a line offset 0.5 pixels

	dim as double sin_2, cos_2, sincos
	sin_2 = sin(-angle) ^ 2
	cos_2 = cos(-angle) ^ 2
	sincos = sin(-angle) * cos(-angle)

	'Coefficients of the general conic quadratic equation Ax^2 + Bxy + Cy^2 + Dx + Ey + F = 0  (D,E = 0)
	'Aprime, Cprime are of the unrotated version
	dim as double Aprime, Cprime
	Aprime = 1.0 / radius ^ 2
	Cprime = 1.0 / semiminor ^ 2

	dim as double A, B, C, F
	A = Aprime * cos_2 + Cprime * sin_2
	B = 2 * (Cprime - Aprime) * sincos
	C = Aprime * sin_2 + Cprime * cos_2
	F = -1.0

	dim as integer xstart = 999999999, xend = -999999999, lastxstart = 999999999, lastxend = -999999999, xs, yi, ys, maxr = large(radius, semiminor) + 1

	for yi = maxr to -maxr step -1
		'Note yi is cartesian coordinates, with the centre of the ellipsis at the origin, NOT screen coordinates!
		'xs, ys are in screen coordinates
		ys = int(y) - yi
		if ys < clipt - 1 or ys > clipb + 1 then continue for

		'Fix y (scanline) and solve for x using quadratic formula (coefficients:)
		dim as double qf_a, qf_b, qf_c
		qf_a = A
		qf_b = B * (yi + ypart)
		qf_c = C * (yi + ypart) ^ 2 + F

		dim as double discrim
		discrim = qf_b^2 - 4.0 * qf_a * qf_c
		if discrim >= 0.0 then
			discrim = sqr(discrim)

			'This algorithm is very sensitive to which way XXX.5 is rounded (normally towards even)...
			xstart = -int(-(x + (-qf_b - discrim) / (2.0 * qf_a) - 0.5))  'ceil(x-0.5), ie. round 0.5 down
			xend = int(x + (-qf_b + discrim) / (2.0 * qf_a) - 0.5)  'floor(x-0.5), ie. round 0.5 up, and subtract 1

			if xstart > xend then  'No pixel centres on this scanline lie inside the ellipse
				if lastxstart <> 999999999 then
					xend = xstart  'We've already started drawing, so must draw at least one pixel
				end if
			end if
		end if

		'Reconsider the previous scanline
		for xs = lastxstart to xstart - 1
			putpixel(fr, xs, ys - 1, col)
		next
		for xs = xend + 1 to lastxend
			putpixel(fr, xs, ys - 1, col)
		next

		dim canskip as bool = YES
		for xs = xstart to xend
			putpixel(fr, xs, ys, col)
			if canskip andalso xs >= lastxstart - 1 then
				'Draw the bare minimum number of pixels (some of these might be needed, but won't know until next scanline)
				dim jumpto as integer = small(xend - 1, lastxend)
				if fillcol <> -1 then
					for xs = xs + 1 to jumpto
						putpixel(fr, xs, ys, fillcol)
					next
				end if
				xs = jumpto
				canskip = NO  'Skipping more than once causes infinite loops
			end if
		next
		lastxstart = xstart
		lastxend = xend
		if discrim >= 0 then xend = xstart - 1  'To draw the last scanline, in the next loop
	next
end sub

'Replaces one colour with another, OR if swapcols is true, swaps the two colours.
sub replacecolor (fr as Frame ptr, c_old as integer, c_new as integer, swapcols as bool = NO)
	if clippedframe <> fr then
		setclip , , , , fr
	end if
	CHECK_FRAME_8BIT(fr)

	for yi as integer = clipt to clipb
		dim sptr as ubyte ptr = fr->image + (yi * fr->pitch)
		for xi as integer = clipl to clipr
			if sptr[xi] = c_old then
				sptr[xi] = c_new
			elseif swapcols and (sptr[xi] = c_new) then
				sptr[xi] = c_old
			end if
		next
	next
end sub

sub swapcolors(fr as Frame ptr, col1 as integer, col2 as integer)
	replacecolor fr, col1, col2, YES
end sub

'Changes a Frame in-place, applying a remapping
sub remap_to_palette (fr as Frame ptr, pal as Palette16 ptr)
	if clippedframe <> fr then
		setclip , , , , fr
	end if
	CHECK_FRAME_8BIT(fr)

	for y as integer = clipt to clipb
		for x as integer = clipl to clipr
			FRAMEPIXEL(x, y, fr) = pal->col(FRAMEPIXEL(x, y, fr))
		next
	next
end sub

sub remap_to_palette (fr as Frame ptr, palmapping() as integer)
	dim pal as Palette16 ptr = Palette16_new_from_indices(palmapping())
	remap_to_palette fr, pal
	Palette16_unload @pal
end sub

' Count the number of occurrences of a color in a Frame (just the clipped region)
function countcolor (fr as Frame ptr, col as integer) as integer
	if clippedframe <> fr then
		setclip , , , , fr
	end if
	CHECK_FRAME_8BIT(fr, 0)

	dim ret as integer = 0
	for yi as integer = clipt to clipb
		for xi as integer = clipl to clipr
			if FRAMEPIXEL(xi, yi, fr) = col then ret += 1
		next
	next
	return ret
end function


'==========================================================================================
'                                      Text routines
'==========================================================================================


function get_font(fontnum as integer, show_err as bool = NO) as Font ptr
	if fontnum < 0 orelse fontnum > ubound(fonts) orelse fonts(fontnum) = null then
		if show_err then
			debugc errPromptBug, "invalid font num " & fontnum
		end if
		return fonts(0)
	else
		return fonts(fontnum)
	end if
end function

'Pass a string, a 0-based offset of the start of the tag (it is assumed the first two characters have already
'been matched as ${ or \8{ as desired), and action and arg pointers, to fill with the parse results. (Action in UPPERCASE)
'Returns 0 for an invalidly formed tag, otherwise the (0-based) offset of the closing }.
function parse_tag(z as string, byval offset as integer, byval action as string ptr, byval arg as int32 ptr) as integer
	dim closebrace as integer = INSTR((offset + 4) + 1, z, "}") - 1
	if closebrace <> -1 then
		*action = ""
		dim j as integer
		for j = 2 to 5
			if isalpha(z[offset + j]) then
				*action += CHR(toupper(z[offset + j]))
			else
				exit for
			end if
		next

		'dim strarg as string = MID(z, offset + j + 1, closebrace - (offset + j))
		'*arg = str2int(strarg)

		'The C standard lib seems a tad more practical than BASIC's (watch out though, scanf will stab you in the back if it sees a chance)
		dim brace as byte
		if isspace(z[offset + j]) orelse sscanf(@z[offset + j], "%d%c", arg, @brace) <> 2 orelse brace <> asc("}") then
			*action = ""
			return 0
		end if
		return closebrace
	end if
	return 0
end function

'FIXME: refactor, making use of OO which we can now use
type PrintStrState
	'Public members (may set before passing to render_text)
	as Font ptr thefont
	as long fgcolor          'Used when resetting localpal. May be -1 for none
	as long bgcolor          'Only used if not_transparent
	as bool not_transparent  'Force non-transparency of layer 1

	'Internal members
	as Font ptr initial_font    'Used when resetting thefont
	as long leftmargin
	as long rightmargin
	as long x
	as long y
	as long startx
	as long charnum

	'Internal members used only if drawing, as opposed to laying out/measuring
	as Palette16 ptr localpal  'NULL if not initialised
	as long initial_fgcolor  'Used when resetting fgcolor
	as long initial_bgcolor  'Used when resetting bgcolor
	as bool initial_not_trans 'Used when resetting bgcolor

	declare constructor()
	declare constructor(rhs as PrintStrState)
	declare destructor()
end type

' Need a default ctor just because there is a copy ctor
constructor PrintStrState()
end constructor

constructor PrintStrState(rhs as PrintStrState)
	memcpy(@this, @rhs, sizeof(PrintStrState))
	if localpal then
		this.localpal->refcount += 1
	end if
end constructor

destructor PrintStrState()
	' Palette16_unload wouldn't actually delete localpal, because it thinks
	' it's cached, so sadly we reimplement it
	'Palette16_unload @localpal
	if localpal then
		localpal->refcount -= 1
		if localpal->refcount <= 0 then
			Palette16_delete @localpal
		end if
	end if
end destructor

'Special signalling characters
#define tcmdFirst      15
#define tcmdState      15
#define tcmdPalette    16
#define tcmdRepalette  17
#define tcmdFont       18  '1 argument: the font number (possibly -1)
#define tcmdLast       18

'Invisible argument: state. (member should not be . prefixed, unfortunately)
'Modifies state, and appends a control sequence to the string outbuf to duplicate the change
'Note: in order to support members that are less than 4 bytes (eg palette colours) some hackery is done, and
'members greater than 4 bytes aren't supported
#macro UPDATE_STATE(outbuf, member, value)
	'Ugh! FB doesn't allow sizeof in #if conditions!
	#if typeof(state.member) <> integer and typeof(state.member) <> long
		#error "UPDATE_STATE: bad member type"
	#endif
	outbuf += CHR(tcmdState) & "      "
	*Cast(short ptr, @outbuf[len(outbuf) - 6]) = Offsetof(PrintStrState, member)
	*Cast(long ptr, @outbuf[len(outbuf) - 4]) = Cast(long, value)
	state.member = value
#endmacro

'Interprets a control sequence (at 0-based offset ch in outbuf) written by UPDATE_STATE,
'modifying state.
#define MODIFY_STATE(state, outbuf, ch) _
	/' dim offset as long = *Cast(short ptr, @outbuf[ch + 1]) '/ _
	/' dim newval as long = *Cast(long ptr, @outbuf[ch + 3]) '/ _
	*Cast(long ptr, Cast(byte ptr, @state) + *Cast(short ptr, @outbuf[ch + 1])) = _
		*Cast(long ptr, @outbuf[ch + 3]) : _
	ch += 6

#define APPEND_CMD0(outbuf, cmd_id) _
	outbuf += CHR(cmd_id)

#define APPEND_CMD1(outbuf, cmd_id, value) _
	outbuf += CHR(cmd_id) & "    " : _
	*Cast(long ptr, @outbuf[len(outbuf) - 4]) = Cast(long, value)

#define READ_CMD(outbuf, ch, variable) _
	variable = *Cast(long ptr, @outbuf[ch + 1]) : _
	ch += 4

'Processes starting from z[state.charnum] until the end of the line, returning a string
'which describes a line fragment. It contains printing characters plus command sequences
'for modifying state. state is passed byval (upon wrapping we would have to undo changes
'to the state, which is too hard).
'endchar is 0 based, and exclusive - normally len(z). FIXME: endchar appears broken
'We also compute the height (height of the tallest font on the line) and the right edge
'(max_x) of the line fragment. You have to know the line height before you can know the y
'coordinate of each character on the line.
'Updates to .x, .y are not written because they can be recreated from the character
'stream, and .charnum is not written (unless updatecharnum is true) because it's too
'expensive. However, .x, .y and .charnum are updated at the end.
'If updatecharnum is true, it is updated only when .charnum jumps; you still need to
'increment after every printing character yourself.
private function layout_line_fragment(z as string, byval endchar as integer, byval state as PrintStrState, byref line_width as integer, byref line_height as integer, byval wide as integer, byval withtags as bool, byval withnewlines as bool, byval updatecharnum as bool = NO) as string
	dim lastspace as integer = -1
	dim lastspace_x as integer
	dim lastspace_outbuf_len as integer
	dim lastspace_line_height as integer
	dim endchar_x as integer             'x at endchar
	dim endchar_outbuf_len as integer = 999999  'Length of outbuf at endchar
	dim ch as integer                    'We use this instead of modifying .charnum
	dim visible_chars as integer         'Number non-control chars we will return
	dim outbuf as string
	'Appending characters one at a time to outbuf is slow, so we delay it.
	'chars_to_add counts the number of delayed characters
	dim chars_to_add as integer = 0

	with state
'debug "layout '" & z & "' from " & .charnum & " at " & .x & "," & .y
		line_height = .thefont->h
		for ch = .charnum to len(z) - 1
			if ch = endchar - 1 then
				'If the final character is a newline and maybe other cases, need to record this
'debug "hit endchar"
				endchar_x = .x
				endchar_outbuf_len = len(outbuf) + chars_to_add
			end if

			if z[ch] = 10 and withnewlines then  'newline
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"
				outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
				chars_to_add = 0
				'Skip past the newline character, but don't add to outbuf
				ch += 1
				if ch >= endchar then
					'FIXME: If the final character is a newline, we don't add a blank line.
					'But text slices do! We should probably do the same here, e.g. removing
					'this if block (and much more work).
					'However, it's difficult to change that, due to other functions depending
					'this one.
					outbuf = left(outbuf, endchar_outbuf_len)
					line_width = endchar_x
					UPDATE_STATE(outbuf, x, endchar_x)
				else
					line_width = .x
					UPDATE_STATE(outbuf, x, .startx)
				end if
				'Purposefully past endchar
				UPDATE_STATE(outbuf, charnum, ch)
				'Reset margins for next paragraph? No.
				'UPDATE_STATE(outbuf, leftmargin, 0)
				'UPDATE_STATE(outbuf, rightmargin, wide)
				return outbuf
			elseif z[ch] = 8 then ' ^H, hide tag
				if z[ch + 1] = asc("{") then
					dim closebrace as integer = instr((ch + 2) + 1, z, "}") - 1
					if closebrace <> -1 then
						'Add delayed characters first
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"

						outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
						chars_to_add = 0
						ch = closebrace
						if updatecharnum then
							UPDATE_STATE(outbuf, charnum, ch)
						end if
						continue for
					end if
				end if
			elseif z[ch] >= tcmdFirst and z[ch] <= tcmdLast then ' special signalling characters. Not allowed! (FIXME: delete this)
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"

				outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
				chars_to_add = 0
				ch += 1	 'skip
				if updatecharnum then
					UPDATE_STATE(outbuf, charnum, ch)
				end if
				continue for
			elseif z[ch] = asc("$") then
				if withtags and z[ch + 1] = asc("{") then
					dim action as string
					dim intarg as int32

					dim closebrace as integer = parse_tag(z, ch, @action, @intarg)
					if closebrace then
						'Add delayed characters first
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"

						outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
						chars_to_add = 0
						if action = "F" then
							'Font
							'Let's preserve the position offset when changing fonts. That way, plain text in
							'the middle of edgetext is also offset +1,+1, so that it lines up visually with it
							'.x += fonts(intarg)->offset.x - .thefont->offset.x
							'.y += fonts(intarg)->offset.y - .thefont->offset.y
							if intarg >= -1 andalso intarg <= ubound(fonts) then
								if intarg = -1 then
									'UPDATE_STATE(outbuf, thefont, .initial_font)
									.thefont = .initial_font
								elseif fonts(intarg) then
									'UPDATE_STATE(outbuf, thefont, fonts(intarg))
									.thefont = fonts(intarg)
								else
									goto badtexttag
								end if
								APPEND_CMD1(outbuf, tcmdFont, intarg)
								line_height = large(line_height, .thefont->h)
							else
								goto badtexttag
							end if
						elseif action = "K" then
							'Foreground colour
							dim col as integer
							if intarg <= -1 then
								col = .initial_fgcolor
							elseif intarg <= 255 THEN
								col = intarg
							else
								goto badtexttag
							end if
							'UPDATE_STATE(outbuf, localpal.col(1), col)
							UPDATE_STATE(outbuf, fgcolor, col)
							APPEND_CMD0(outbuf, tcmdRepalette)
							'No need to update localpal here by calling build_text_palette
						elseif action = "KB" then
							'Background colour
							dim col as integer
							if intarg <= -1 then
								col = .initial_bgcolor
								if .not_transparent <> .initial_not_trans then
									UPDATE_STATE(outbuf, not_transparent, .initial_not_trans)
								end if
							elseif intarg <= 255 THEN
								col = intarg
								if .not_transparent = NO then
									UPDATE_STATE(outbuf, not_transparent, YES)
								end if
							else
								goto badtexttag
							end if
							'UPDATE_STATE(outbuf, localpal.col(0), col)
							UPDATE_STATE(outbuf, bgcolor, col)
							APPEND_CMD0(outbuf, tcmdRepalette)
							'No need to update localpal here by calling build_text_palette
						elseif action = "KP" then
							'Font palette
							if intarg >= 0 and intarg <= gen(genMaxPal) then
								APPEND_CMD1(outbuf, tcmdPalette, intarg)
								'No need up update palette or fgcolor here
								'(don't want to duplicate that logic here)
							else
								goto badtexttag
							end if
						elseif action = "LM" then
							UPDATE_STATE(outbuf, leftmargin, intarg)
						elseif action = "RM" then
							UPDATE_STATE(outbuf, rightmargin, wide - intarg)
						else
							goto badtexttag
						end if
						ch = closebrace
						if updatecharnum then
							UPDATE_STATE(outbuf, charnum, ch)
						end if
						continue for
					end if

					badtexttag:
				end if
			elseif z[ch] = asc(" ") then
				lastspace = ch
				lastspace_outbuf_len = len(outbuf) + chars_to_add
				lastspace_x = .x
				lastspace_line_height = line_height
			end if

			.x += .thefont->w(z[ch])
			if .x > .startx + .rightmargin then
'debug "rm = " & .rightmargin & " lm = " & .leftmargin
				if lastspace > -1 and .x - lastspace_x < 3 * (.rightmargin - .leftmargin) \ 5 then
					'Split at the last space

					if chars_to_add then
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"

						outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
					end if
					outbuf = left(outbuf, small(endchar_outbuf_len, lastspace_outbuf_len))
					if lastspace < endchar then
						line_width = lastspace_x
						UPDATE_STATE(outbuf, x, .startx + .leftmargin)
					else
						line_width = endchar_x
					end if
					line_height = lastspace_line_height
					UPDATE_STATE(outbuf, charnum, lastspace + 1)

					return outbuf
				else
					'Split the word instead, it would just look ugly to break the line
					if visible_chars = 0 then
						'Always output at least one character
						chars_to_add += 1
						ch += 1
					end if
					exit for
				end if
			end if

			'Add this character to outbuf. But not immediately.
			chars_to_add += 1
			visible_chars += 1
		next

		'Hit end of text, or splitting word
		if chars_to_add then
'debug "add " & chars_to_add & " chars before " & ch & " : '" & Mid(z, 1 + ch - chars_to_add, chars_to_add) & "'"
			outbuf += Mid(z, 1 + ch - chars_to_add, chars_to_add)
		end if
		'Why do we always set x and charnum at the end of the string?
		if ch <= endchar then
'debug "exiting layout_line_fragment, ch = " & ch & ", .x = " & .x
			line_width = .x
			UPDATE_STATE(outbuf, x, .startx + .leftmargin)
		else
'debug "exiting layout_line_fragment, ch = " & ch & ", endchar_x = " & endchar_x
			outbuf = left(outbuf, endchar_outbuf_len)
			line_width = endchar_x
			UPDATE_STATE(outbuf, x, endchar_x)
		end if
		UPDATE_STATE(outbuf, charnum, ch)
		'Preserve .leftmargin and .rightmargin

		return outbuf
	end with
end function

'Build state.localpal
sub build_text_palette(byref state as PrintStrState, byval srcpal as Palette16 ptr)
	with state
		if state.localpal = NULL then
			' FIXME: This returns a non-refcounted palette16, but we want
			' a refcount, which we're forced to manage ourselves (see destructor)
			state.localpal = Palette16_new()
			state.localpal->refcount = 1
		end if
		if srcpal then
			memcpy(@.localpal->col(0), @srcpal->col(0), srcpal->numcolors)
			.localpal->numcolors = srcpal->numcolors
		end if
		.localpal->col(0) = .bgcolor
		if .fgcolor > -1 then
			.localpal->col(1) = .fgcolor
		end if
		if srcpal = NULL and .fgcolor = -1 then
			debug "render_text: Drawing a font without a palette or foreground colour!"
		end if
'debug "build_text_palette: bg = " & .bgcolor & " fg = "& .fgcolor & " outline = " & .thefont->outline_col
		'Outline colours are a hack, hopefully temp.
		if .thefont->outline_col > 0 then
			.localpal->col(.thefont->outline_col) = uilook(uiOutline)
		end if
	end with
end sub

'Processes a parsed line, updating the state passed to it, and also optionally draws one of the layers (if reallydraw)
sub draw_line_fragment(byval dest as Frame ptr, byref state as PrintStrState, byval layer as integer, parsed_line as string, byval reallydraw as bool)
	dim arg as integer
	dim as Frame charframe
	charframe.mask = NULL
	charframe.refcount = NOREFC

	with state
'debug "draw frag: x=" & .x & " y=" & .y & " char=" & .charnum & " reallydraw=" & reallydraw & " layer=" & layer
		for ch as integer = 0 to len(parsed_line) - 1
			if parsed_line[ch] = tcmdState then
				'Control sequence. Make a change to state, and move ch past the sequence
				MODIFY_STATE(state, parsed_line, ch)

			elseif parsed_line[ch] = tcmdFont then
				READ_CMD(parsed_line, ch, arg)
				if arg >= -1 andalso arg <= ubound(fonts) then
					if arg = -1 then
						'UPDATE_STATE(outbuf, thefont, .initial_font)
						.thefont = .initial_font
					elseif fonts(arg) then
						'UPDATE_STATE(outbuf, thefont, fonts(arg))
						.thefont = fonts(arg)
					else
						'This should be impossible, because layout_line_fragment has already checked this
						debugc errPromptBug, "draw_line_fragment: NULL font!"
					end if
				else
					'This should be impossible, because layout_line_fragment has already checked this
					debugc errPromptBug, "draw_line_fragment: invalid font!"
				end if
				if reallydraw then
					'In case .fgcolor == -1 and .thefont->pal == NULL. Palette changes are per-font,
					'so reset the colour.
					if .fgcolor = -1 then .fgcolor = .initial_fgcolor
					'We rebuild the local palette using either the font's palette or from scratch
					build_text_palette state, .thefont->pal
				end if

			elseif parsed_line[ch] = tcmdPalette then
				READ_CMD(parsed_line, ch, arg)
				if reallydraw then
					dim pal as Palette16 ptr
					pal = Palette16_load(arg)
					if pal then
						'Palettes override the foreground colour (but not background or outline)
						.fgcolor = -1
						build_text_palette state, pal
						Palette16_unload @pal
					end if
					'FIXME: in fact pal should be kept around, for tcmdRepalette
				end if

			elseif parsed_line[ch] = tcmdRepalette then
				if reallydraw then
					'FIXME: if we want to support switching to a non-font palette, then
					'that palette should be stored in state and used here
					build_text_palette state, .thefont->pal
				end if

			else
				'Draw a character

				'Fun hack! Console support
				if layer = 1 and gfx_printchar <> NULL then
					gfx_printchar(parsed_line[ch], .x, .y, .fgcolor)
				end if

				'Print one character past the end of the line
				if reallydraw and .x <= clipr then
					if .thefont->layers(layer) <> NULL then
						with .thefont->layers(layer)->chdata(parsed_line[ch])
							charframe.image = state.thefont->layers(layer)->spr->image + .offset
							charframe.w = .w
							charframe.h = .h
							charframe.pitch = .w
'debug " <" & (state.x + .offx) & "," & (state.y + .offy) & ">"
							dim trans as bool = YES
							'FIXME: why do we only allow 1-layer fonts to be non transparent?
							'(2-layer fonts would need layer 0 to be opaque)
							'ALSO, this would stuff up ${KB#} on 2-layer fonts
							if layer = 1 and state.not_transparent then trans = NO
							frame_draw_internal(@charframe, intpal(), state.localpal, state.x + .offx, state.y + .offy - state.thefont->h, , trans, dest)
						end with
					end if
				end if

				'Note: do not use charframe.w, that's just the width of the sprite
				.x += .thefont->w(parsed_line[ch])
			end if
		next
	end with
end sub


'Draw a string. You will normally want to use one of the friendlier overloads for this,
'probably the most complicated function in the engine.
'
'Arguments:
'
'Pass in a reference to a (fresh!!) PrintStrState object with .thefont and .fgcolor set
'.fgcolor can be -1 for no colour (just use font palette).
'.not_transparent and .bgcolor (only used if .not_transparent) may also be set
'
'At least one of <s>pal and</s> the (current) font pal and .fgcolor must be not NULL/-1.
'This can be ensured by starting with either a palette or a .fgcolor!=-1
'FIXME: pal is currently disabled; palette handling needs rewriting.
'
'endchar shouldn't be used; currently broken?
'
'If withtags is false then no tags are processed.
'If withtags is true, the follow "basic texttags" are processed:
'  (These will change!)
' ${F#}  changes to font # or return to initial font if # == -1
' ${K#}  changes foreground/first colour, or return to initial colour if # == -1
'        (Note that this does disable the foreground colour, unless the initial fg colour was -1!)
' ${KB#} changes the background colour, and turns on not_transparent.
'        Specify -1 to restore previous background colour and transparency
'        FIXME: ${KB0} does NOT switch to transparency, but an initial bgcol of 0 IS transparent!
' ${KP#} changes to palette # (-1 is invalid) (Maybe should make ${F-1} return to the default)
'        (Note, palette changes are per-font, and expire when the font changes)
' ${LM#} sets left margin for the current line, in pixels
' ${RM#} sets right margin for the current line, in pixels
'Purposefully no way to set background colour.
'Unrecognised and invalid basic texttags are printed as normal.
'ASCII character 8 can be used to hide texttags by overwriting the $, like so: \008{X#}
'
'Clipping and wrapping:
'If you specify a page width (the default is "infinite"), then text automatically wraps according
'to current margins. Otherwise there is no limit on the right (not even the edge of the screen).
'xpos is the left limit, and xpos+wide is the right limit from which margins are measured (inwards).
'(FIXME: why is wide measured relative to xpos?)
'Drawn text is NOT clipped to this region, use setclip or frame_new_view for that.
'This region may be larger than the clip area.
'If withnewlines is true, then newlines (ASCII character 10) are respected
'instead of printed as normal characters.
'
'If you want to skip some number of lines, you should clip, and draw some number of pixels
'above the clipping rectangle.
'
sub render_text (dest as Frame ptr, byref state as PrintStrState, text as string, endchar as integer = 999999, xpos as RelPos, ypos as RelPos, wide as RelPos = 999999, pal as Palette16 ptr = NULL, withtags as bool = YES, withnewlines as bool = YES)
', cached_state as PrintStrStatePtr = NULL, use_cached_state as bool = YES)

'static tog as integer = 0
'tog xor= 1
'dim t as double = timer

	if dest = null then debug "printstr: NULL dest" : exit sub

	if clippedframe <> dest then
		setclip , , , , dest
	end if

	'check bounds skipped because this is now quite hard to tell (checked in draw_clipped)

'debug "printstr '" & text & "' (len=" & len(text) & ") wide = " & wide & " tags=" & withtags & " nl=" & withnewlines

	wide = relative_pos(wide, dest->w)

	' Only pre-compute the text dimensions if required for anchoring, as it's quite expensive
	dim as AlignType xanchor, yanchor, xshow, yshow
	RelPos_decode xpos, 0, 0, xanchor, xshow
	RelPos_decode ypos, 0, 0, yanchor, yshow
	dim finalsize as StringSize
	if xanchor <> alignLeft or yanchor <> alignLeft or xshow <> alignCenter or yshow <> alignCenter then
		text_layout_dimensions @finalsize, text, endchar, , wide, state.thefont, withtags, withnewlines
	end if

	with state
		/'
		if cached_state <> NULL and use_cached_state then
			state = *cached_state
			cached_state = NULL
		else
		'/
			'if pal then
			'	build_text_palette state, pal
			'else
				build_text_palette state, .thefont->pal
			'end if
			.initial_font = .thefont
			.initial_fgcolor = .fgcolor
			.initial_bgcolor = .bgcolor
			.initial_not_trans = .not_transparent
			.charnum = 0
			.x = relative_pos(xpos, dest->w, finalsize.w) + .thefont->offset.x
			.y = relative_pos(ypos, dest->h, finalsize.h) + .thefont->offset.y
			.startx = .x
			'Margins are measured relative to xpos
			.leftmargin = 0
			.rightmargin = wide
		'end if

		dim as bool visibleline  'Draw this line of text?

		'We have to process both layers, even if the current font has only one layer,
		'in case the string switches to a font that has two!
		dim prev_state as PrintStrState = state
		dim prev_parse as string
		dim prev_visible as bool
		dim draw_layer1 as bool = NO  'Don't draw on first loop

		if endchar > len(text) then endchar = len(text)
		do
			dim line_height as integer
			dim parsed_line as string = layout_line_fragment(text, endchar, state, 0, line_height, wide, withtags, withnewlines)
'debug "parsed: " + parsed_line
			'Print at least one extra line above and below the visible region, in case the
			'characters are big (we only approximate this policy, with the current font height)
			visibleline = (.y + line_height > clipt - .thefont->h AND .y < clipb + .thefont->h)
'if tog then visibleline = NO
'debug "vis: " & visibleline

			'FIXME: state caching was meant to kick in after the first visible line of text, not here;
			'however need to rethink how it should work
/'
			if cached_state then
				*cached_state = state
				cached_state = NULL  'Don't save again
			end if
'/
			.y += line_height

			'Update state while drawing layer 0 (if visible)
			draw_line_fragment(dest, state, 0, parsed_line, visibleline)

			if draw_layer1 then
				'Now update prev_state (to the beginning of THIS line) while drawing layer 1
				'for the previous line. Afterwards, prev_state will be identical to state
				'as it was at the start of this loop.
				draw_line_fragment(dest, prev_state, 1, prev_parse, prev_visible)
'debug "prev.charnum=" & prev_state.charnum
				if prev_state.charnum >= endchar then /'debug "text end" :'/ exit do
				if prev_state.y > clipb + prev_state.thefont->h then exit do
			end if
			draw_layer1 = YES
			prev_parse = parsed_line
			prev_visible = visibleline
			prev_state.y += line_height
		loop
	end with
't = timer - t
'debug "prinstr" & tog & " len " & len(text) & " in " & t*1000 & "ms"
end sub

'Calculate size of part of a block of text when drawn, returned in retsize
'NOTE: Edged font has width 1 pixel more than Plain font, due to .offset.x.
sub text_layout_dimensions (retsize as StringSize ptr, z as string, endchar as integer = 999999, maxlines as integer = 999999, wide as integer = 999999, fontp as Font ptr, withtags as bool = YES, withnewlines as bool = YES)
'debug "DIMEN char " & endchar
	dim state as PrintStrState
	with state
		'.localpal/?gcolor/initial_?gcolor/transparency non-initialised
		.thefont = fontp
		.initial_font = .thefont
		.charnum = 0
		.x = .thefont->offset.x
		.y = .thefont->offset.y
		'Margins are measured relative to xpos
		.leftmargin = 0
		.rightmargin = wide

		dim maxwidth as integer = 0
		dim line_width as integer = 0
		dim line_height as integer = 0
		retsize->lines = 0

		if endchar > len(z) then endchar = len(z)
		while .charnum < len(z)
			if .charnum > endchar then exit while
			'If .charnum = endchar, the last line is zero length, but should be included.
			'.charnum won't advance, so need extra check to prevent infinite loop!
			dim exitloop as bool = (.charnum = endchar)
			dim parsed_line as string = layout_line_fragment(z, endchar, state, line_width, line_height, wide, withtags, withnewlines)
			retsize->lines += 1
'debug "parsed a line, line_width =" & line_width
			maxwidth = large(maxwidth, line_width)

			'Update state
			.y += line_height
			draw_line_fragment(NULL, state, 0, parsed_line, NO)
'debug "now " & .charnum & " at " & .x & "," & .y
			if exitloop then exit while
		wend

		retsize->endchar = .charnum
		retsize->w = maxwidth
		retsize->h = .y
		retsize->lastw = line_width
		retsize->lasth = line_height
		retsize->finalfont = .thefont
'debug "end DIM  char=" & .charnum
	end with
end sub

'Returns the length in pixels of the longest line of a *non-autowrapped* string.
function textwidth(text as string, fontnum as integer = fontPlain, withtags as bool = YES, withnewlines as bool = YES) as integer
	dim retsize as StringSize
	text_layout_dimensions @retsize, text, , , , get_font(fontnum), withtags, withnewlines
	return retsize.w
end function

'Returns the width and height of an autowrapped string.
'Specify the wrapping width; 'wide' might include rWidth for the width of the screen
'(which is what the page arg is for).
function textsize(text as string, wide as RelPos = rWidth, fontnum as integer = fontPlain, withtags as bool = YES, page as integer = -1) as XYPair
	if page = -1 then page = vpage
	wide = relative_pos(wide, vpages(page)->w)
	dim retsize as StringSize
	text_layout_dimensions @retsize, text, , , wide, get_font(fontnum), withtags, YES
	return XY(retsize.w, retsize.h)
end function

'Returns the default height of a line of text of a certain font.
'Warning: this currently returns 10 for 8x8 fonts, because that's what text slices use. Sigh.
'However standardmenu (calc_menustate_size) by default uses 9 for fontEdged and 8 for fontPlain
'and draw_menu by default uses 10. Nonstandard menus use 8-10.
function lineheight(fontnum as integer = fontEdged) as integer
	return get_font(fontnum, YES)->h
end function

'xpos and ypos passed to use same cached state
sub find_point_in_text (byval retsize as StringCharPos ptr, byval seekx as integer, byval seeky as integer, z as string, byval wide as integer = 999999, byval xpos as integer = 0, byval ypos as integer = 0, byval fontnum as integer, byval withtags as bool = YES, byval withnewlines as bool = YES)
	dim state as PrintStrState
	with state
		'.localpal/?gcolor/initial_?gcolor/transparency non-initialised
		.thefont = get_font(fontnum)
		.initial_font = .thefont
		.charnum = 0
		.x = xpos + .thefont->offset.x
		.y = ypos + .thefont->offset.y
		'Margins are measured relative to xpos
		.leftmargin = 0
		.rightmargin = wide

		dim delayedmatch as bool = NO
		dim line_width as integer
		dim line_height as integer
		dim arg as integer

		retsize->exacthit = NO
		'retsize->w = .thefont->h  'Default for if we go off the end of the text

		while .charnum < len(z)
			dim parsed_line as string = layout_line_fragment(z, len(z), state, line_width, line_height, wide, withtags, withnewlines, YES)
			.y += line_height
			'.y now points to 1 pixel past the bottom of the line fragment

			'Update state
			for ch as integer = 0 to len(parsed_line) - 1
				if parsed_line[ch] = tcmdState then
					'Make a change to the state
					.charnum += 1   'FIXME: this looks wrong
					MODIFY_STATE(state, parsed_line, ch)
				elseif parsed_line[ch] = tcmdFont then
					READ_CMD(parsed_line, ch, arg)
					.thefont = fonts(arg)
				elseif parsed_line[ch] = tcmdPalette then
					READ_CMD(parsed_line, ch, arg)
				else

					dim w as integer = .thefont->w(parsed_line[ch])
					'Draw a character
					if delayedmatch then
						'retsize->w = w
						exit while
					end if
					.x += w
					if .y > seeky and .x > seekx then
'debug "FIND IN: hit w/ x = " & .x
						'retsize->w = w
						retsize->exacthit = YES
						.x -= w
						exit while
					end if
					.charnum += 1
				end if
			next

			if .y > seeky then
				'Position was off the end of the line
				if .charnum > 0 then
					dim lastchar as ubyte = z[.charnum - 1]
					if lastchar = 32 or (lastchar = 10 andalso withnewlines) then
						'This point is actually on a space/newline, which was
						'not added to parsed_string. So don't delay.
						retsize->exacthit = YES
						.x = line_width
						.charnum -= 1
						exit while
					end if
				end if
				delayedmatch = YES
'debug "FIND IN: delayed"
			end if
		wend

		retsize->charnum = .charnum
		retsize->x = .x
		retsize->y = .y - .thefont->h
		retsize->h = .thefont->h
		retsize->lineh = line_height
	end with
end sub

'the old printstr -- no autowrapping
sub printstr (text as string, x as RelPos, y as RelPos, page as integer, withtags as bool = NO, fontnum as integer = fontPlain)
	dim state as PrintStrState
	state.thefont = get_font(fontnum)
	if textbg <> 0 then state.not_transparent = YES
	state.bgcolor = textbg
	state.fgcolor = textfg

	render_text (vpages(page), state, text, , x, y, , , withtags, NO)
end sub

'this doesn't autowrap either
sub edgeprint (text as string, x as RelPos, y as RelPos, col as integer, page as integer, withtags as bool = NO, withnewlines as bool = NO)
	'preserve the old behaviour (edgeprint used to call textcolor)
	textfg = col
	textbg = 0

	dim state as PrintStrState
	state.thefont = fonts(fontEdged)
	state.fgcolor = col

	render_text (vpages(page), state, text, , x, y, , , withtags, withnewlines)
end sub

'A flexible edgeprint/printstr replacement.
'Either specify the colour, or omit it and use textcolor().
'Wraps the text at 'wide'; pass "rWidth - x" to wrap at the right edge of the screen.
sub wrapprint (text as string, x as RelPos, y as RelPos, col as integer = -1, page as integer, wide as RelPos = rWidth, withtags as bool = YES, fontnum as integer = fontEdged)
	dim state as PrintStrState
	state.thefont = fonts(fontnum)
	if col = -1 then
		state.fgcolor = textfg
		state.bgcolor = textbg
		if textbg <> 0 then state.not_transparent = YES
	else
		state.fgcolor = col
		state.bgcolor = 0
	end if
	render_text (vpages(page), state, text, , x, y, wide, , withtags, YES)
end sub

sub textcolor (byval fg as integer, byval bg as integer)
	textfg = fg
	textbg = bg
end sub

function fgcol_text(text as string, byval colour as integer) as string
	return "${K" & colour & "}" & text & "${K-1}"
end function

function bgcol_text(text as string, byval colour as integer) as string
	return "${KB" & colour & "}" & text & "${KB-1}"
end function


'==========================================================================================
'                                           Fonts
'==========================================================================================


'This deletes a Font object pointed to by a pointer. It's OK to call on a ptr to a NULL ptr
sub font_unload (fontpp as Font ptr ptr)
	if fontpp = null then showerror "font_unload: passed NULL" : exit sub
	dim fontp as font ptr = *fontpp
	if fontp = null then exit sub

	for i as integer = 0 to 1
		if fontp->layers(i) then
			fontp->layers(i)->refcount -= 1
			if fontp->layers(i)->refcount <= 0 then
				frame_unload @fontp->layers(i)->spr
				deallocate(fontp->layers(i))
			end if
			fontp->layers(i) = NULL
		end if
	next

	Palette16_unload @fontp->pal
	deallocate fontp
	*fontpp = NULL
end sub

'Doesn't create a Frame
private function fontlayer_new () as FontLayer ptr
	dim ret as FontLayer ptr
	ret = callocate(sizeof(FontLayer))
	ret->refcount = 1
	return ret
end function

private function fontlayer_duplicate (byval srclayer as FontLayer ptr) as FontLayer ptr
	dim ret as FontLayer ptr
	ret = callocate(sizeof(FontLayer))
	memcpy(ret, srclayer, sizeof(FontLayer))
	ret->spr = frame_duplicate(srclayer->spr)
	ret->refcount = 1
	return ret
end function

'Create a version of a font with an outline around each character (in a new palette colour)
function font_create_edged (basefont as Font ptr) as Font ptr
	if basefont = null then
		debugc errPromptBug, "font_create_edged wasn't passed a font!"
		return null
	end if
	if basefont->layers(1) = null then
		debugc errPromptBug, "font_create_edged was passed a blank font!"
		return null
	end if
	CHECK_FRAME_8BIT(basefont->layers(1)->spr, NULL)

	dim newfont as Font ptr = callocate(sizeof(Font))

	newfont->layers(0) = fontlayer_new()
	'Share layer 1
	newfont->layers(1) = basefont->layers(1)
	newfont->layers(1)->refcount += 1

	dim size as integer
	'since you can only WITH one thing at a time
	dim bchr as FontChar ptr
	bchr = @basefont->layers(1)->chdata(0)

	dim as integer ch

	for ch = 0 to 255
		newfont->w(ch) = basefont->w(ch)

		with newfont->layers(0)->chdata(ch)
			.offset = size
			.offx = bchr->offx - 1
			.offy = bchr->offy - 1
			.w = bchr->w + 2
			.h = bchr->h + 2
			size += .w * .h
		end with
		bchr += 1
	next

	'This is a hack; create a size*1 size frame, which we use as a buffer for pixel data
	newfont->layers(0)->spr = frame_new(size, 1, , YES)

	newfont->h = basefont->h  '+ 2
	newfont->offset = basefont->offset
	newfont->cols = basefont->cols
	if basefont->outline_col = 0 then
		'Doesn't already have an outline colour
		newfont->cols += 1
		newfont->outline_col = newfont->cols
	else
		newfont->outline_col = basefont->outline_col
	end if

	'Stuff currently hardcoded to keep edged font working as before
	newfont->offset.x = 1
	newfont->offset.y = 1
	'newfont->h += 2

	'dim as ubyte ptr maskp = basefont->layers(0)->spr->mask
	dim as ubyte ptr sptr
	dim as ubyte ptr srcptr = newfont->layers(1)->spr->image
	dim as integer x, y

	for ch = 0 to 255
		with newfont->layers(0)->chdata(ch)
			sptr = newfont->layers(0)->spr->image + .offset + .w + 1
			for y = 1 to .h - 2
				for x = 1 to .w - 2
					if *srcptr then
						sptr[-.w + 0] = newfont->outline_col
						sptr[  0 - 1] = newfont->outline_col
						sptr[  0 + 1] = newfont->outline_col
						sptr[ .w + 0] = newfont->outline_col
					end if
					'if *sptr = 0 then *maskp = 0 else *maskp = &hff
					sptr += 1
					srcptr += 1
					'maskp += 8
				next
				sptr += 2
			next
		end with
	next

	return newfont
end function

'Create a version of a font with a drop shadow (in a new palette colour)
function font_create_shadowed (basefont as Font ptr, xdrop as integer = 1, ydrop as integer = 1) as Font ptr
	if basefont = null then
		debug "createshadowfont wasn't passed a font!"
		return null
	end if
	if basefont->layers(1) = null then
		debug "createshadowfont was passed a blank font!"
		return null
	end if
	CHECK_FRAME_8BIT(basefont->layers(1)->spr, NULL)

	dim newfont as Font ptr = callocate(sizeof(Font))

	memcpy(newfont, basefont, sizeof(Font))

	'Copy layer 1 from the old font to layer 0 of the new
	newfont->layers(0) = fontlayer_duplicate(basefont->layers(1))

	'Share layer 1 with the base font
	newfont->layers(1)->refcount += 1

	if newfont->outline_col = 0 then
		'Doesn't already have an outline colour
		newfont->cols += 1
		newfont->outline_col = newfont->cols
	end if

	for ch as integer = 0 to 255
		with newfont->layers(0)->chdata(ch)
			.offx += xdrop
			.offy += ydrop
		end with
	next

	with *newfont->layers(0)->spr
		for i as integer = 0 to .w * .h - 1
			if .image[i] then
				.image[i] = newfont->outline_col
			end if
		next
	end with

	return newfont
end function

function font_loadold1bit (fontdata as ubyte ptr) as Font ptr
	dim newfont as Font ptr = callocate(sizeof(Font))

	newfont->layers(1) = fontlayer_new()
	newfont->layers(1)->spr = frame_new(8, 256 * 8)
	newfont->h = 10  'I would have said 9, but this is what was used in text slices
	newfont->offset.x = 0
	newfont->offset.y = 0
	newfont->cols = 1
	newfont->outline_col = 0  'None

	'dim as ubyte ptr maskp = newfont->layers(1)->spr->mask
	dim as ubyte ptr sptr = newfont->layers(1)->spr->image

	dim as integer ch, x, y
	dim as integer fi 'font index
	dim as integer fstep

	for ch = 0 to 255
		newfont->w(ch) = 8
		with newfont->layers(1)->chdata(ch)
			.w = 8
			.h = 8
			.offset = 64 * ch
		end with

		'find fontdata index, bearing in mind that the data is stored
		'2-bytes at a time in 4-byte integers, due to QB->FB quirks,
		'and fontdata itself is a byte pointer. Because there are
		'always 8 bytes per character, we will always use exactly 4
		'ints, or 16 bytes, making the initial calc pretty simple.
		fi = ch * 16
		'fi = ch * 8	'index to fontdata
		fstep = 1 'used because our indexing is messed up, see above
		for x = 0 to 7
			for y = 0 to 7
				*sptr = (fontdata[fi] shr y) and 1
				'if *sptr = 0 then *maskp = 0 else *maskp = &hff
				sptr += 8
				'maskp += 8
			next
			fi = fi + fstep
			fstep = iif(fstep = 1, 3, 1) 'uneven steps due to 2->4 byte thunk
			sptr += 1 - 8 * 8
			'maskp += 1 - 8 * 8
		next
		sptr += 8 * 8 - 8
		'maskp += 8 * 8 - 8
	next

	return newfont
end function

'Load each character from an individual BMP in a directory, falling back to some other
'font for missing BMPs
'This function is for testing purposes only, and will be removed unless this shows some use:
'uses hardcoded values
function font_loadbmps (directory as string, fallback as Font ptr = null) as Font ptr
	dim newfont as Font ptr = callocate(sizeof(Font))

	newfont->layers(0) = null
	newfont->layers(1) = fontlayer_new()
	'Hacky: start by allocating 4096 pixels, expand as needed
	newfont->layers(1)->spr = frame_new(1, 4096)
	newfont->cols = 1  'hardcoded
	newfont->outline_col = 0  'None

	dim maxheight as integer
	if fallback then
		maxheight = fallback->h
		newfont->offset.x = fallback->offset.x
		newfont->offset.y = fallback->offset.y
		newfont->cols = fallback->cols
	end if

	dim as ubyte ptr image = newfont->layers(1)->spr->image
	dim as ubyte ptr sptr
	dim as integer size = 0
	dim as integer i
	dim f as string
	dim tempfr as Frame ptr
	dim bchr as FontChar ptr
	bchr = @fallback->layers(1)->chdata(0)

	for i = 0 to 255
		with newfont->layers(1)->chdata(i)
			f = finddatafile(directory & SLASH & i & ".bmp", NO)
			if isfile(f) then
				'FIXME: awful stuff
				tempfr = frame_import_bmp_raw(f)  ', master())

				.offset = size
				.offx = 0
				.offy = 0
				.w = tempfr->w
				.h = tempfr->h
				if .h > maxheight then maxheight = .h
				newfont->w(i) = .w
				size += .w * .h
				image = reallocate(image, size)
				sptr = image + .offset
				memcpy(sptr, tempfr->image, .w * .h)
				frame_unload @tempfr
			else
				if fallback = null ORELSE fallback->layers(1) = null then
					debug "font_loadbmps: " & i & ".bmp missing and fallback font not provided"
					font_unload @newfont
					return null
				end if

				.offset = size
				.offx = bchr->offx
				.offy = bchr->offy
				.w = bchr->w
				.h = bchr->h
				newfont->w(i) = .w
				size += .w * .h
				image = reallocate(image, size)
				memcpy(image + .offset, fallback->layers(1)->spr->image + bchr->offset, .w * .h)
			end if
		end with

		bchr += 1
	next

	newfont->layers(1)->spr->image = image
	newfont->h = maxheight

	return newfont
end function

'Load a font from a BMP which contains all 256 characters in a 16x16 grid (all characters the same size)
function font_loadbmp_16x16 (filename as string) as Font ptr
	dim bmp as Frame ptr
	bmp = frame_import_bmp_raw(filename)

	if bmp = NULL then
		debug "font_loadbmp_16x16: couldn't load " & filename
		return null
	end if

	if bmp->w MOD 16 ORELSE bmp->h MOD 16 then
		debug "font_loadbmp_16x16: " & filename & ": bad dimensions " & bmp->w & "*" & bmp->h
		frame_unload @bmp
		return null
	end if

	dim newfont as Font ptr = callocate(sizeof(Font))

	dim as integer charw, charh
	charw = bmp->w \ 16
	charh = bmp->h \ 16
	newfont->h = charh
	newfont->offset.x = 0
	newfont->offset.y = 0
	newfont->outline_col = 0  'None
	newfont->layers(0) = null
	newfont->layers(1) = fontlayer_new()

	'"Linearise" the characters. In future this will be unnecessary
	newfont->layers(1)->spr = frame_new(charw, charh * 256)

	dim as integer size = 0

	for i as integer = 0 to 255
		with newfont->layers(1)->chdata(i)
			.offset = size
			.offx = 0
			.offy = 0
			.w = charw
			.h = charh
			newfont->w(i) = .w
			size += .w * .h
			dim tempview as Frame ptr
			tempview = frame_new_view(bmp, charw * (i MOD 16), charh * (i \ 16), charw, charh)
			'setclip , charh * i, , charh * (i + 1) - 1, newfont->layers(1)->spr
			frame_draw tempview, , 0, charh * i, 1, NO, newfont->layers(1)->spr
			frame_unload @tempview
		end with
	next

	'Find number of used colours
	newfont->cols = 0
	dim as ubyte ptr image = bmp->image
	for i as integer = 0 to bmp->pitch * bmp->h - 1
		if image[i] > newfont->cols then newfont->cols = image[i]
	next

	frame_unload @bmp
	return newfont
end function

sub setfont (ohf_font() as integer)
	font_unload @fonts(fontPlain)
	font_unload @fonts(fontEdged)
	font_unload @fonts(fontShadow)
	fonts(fontPlain) = font_loadold1bit(cast(ubyte ptr, @ohf_font(0)))
	fonts(fontEdged) = font_create_edged(fonts(fontPlain))
	fonts(fontShadow) = font_create_shadowed(fonts(fontPlain), 1, 2)
end sub

'NOTE: the following two functions are for the old style fonts, they will
'be removed when switching to the new system supporting unicode fonts

'These old style fonts store the type of the font in first integer (part of character
'0). The default "Latin-1.ohf" and "OHRRPGCE Default.ohf" fonts are marked as Latin 1, so
'any font derived from them will be too (ability to change the type only added in Callipygous)

function get_font_type (ohf_font() as integer) as fontTypeEnum
	if ohf_font(0) <> ftypeASCII and ohf_font(0) <> ftypeLatin1 then
		debugc errPromptBug, "Unknown font type ID " & ohf_font(0)
		return ftypeASCII
	end if
	return ohf_font(0)
end function

sub set_font_type (ohf_font() as integer, ty as fontTypeEnum)
	if ty <> ftypeASCII and ty <> ftypeLatin1 then
		debugc errPromptBug, "set_font_type: bad type " & ty
	end if
	ohf_font(0) = ty
end sub


'==========================================================================================
'                                       BMP routines
'==========================================================================================
'other formats are probably quite simple
'with Allegro or SDL or FreeImage, but we'll stick to this for now.


sub surface_export_bmp (f as string, byval surf as Surface Ptr, maspal() as RGBcolor)
	if surf->format = SF_32bit then
		surface_export_bmp24(f, surf)
	else
		'A wrapper
		dim fr as Frame
		fr.w = surf->width
		fr.h = surf->height
		fr.pitch = surf->pitch
		fr.image = surf->pPaletteData
		fr.mask = surf->pPaletteData
		frame_export_bmp8(f, @fr, maspal())
	end if
end sub

sub surface_export_bmp24 (f as string, byval surf as Surface Ptr)
	dim argb as RGBQUAD
	dim as integer of, y, i, skipbytes
	dim as RGBcolor ptr sptr
	dim as ubyte buf(3)

	if surf->format <> SF_32bit then
		showerror "surface_export_bmp24 got 8bit Surface"
		exit sub
	end if

	of = write_bmp_header(f, surf->width, surf->height, 24)
	if of = -1 then exit sub

	skipbytes = 4 - (surf->width * 3 mod 4)
	if skipbytes = 4 then skipbytes = 0
	sptr = surf->pColorData + (surf->height - 1) * surf->pitch
	for y = surf->height - 1 to 0 step -1
		'put is possibly the most screwed up FB builtin; the use of the fput wrapper soothes the soul
		for x as integer = 0 to surf->width - 1
			fput(of, , @sptr[x], 3)
		next
		sptr -= surf->pitch
		'pad to 4-byte boundary
		fput(of, , @buf(0), skipbytes)
	next

	close #of
end sub

sub frame_export_bmp8 (f as string, byval fr as Frame Ptr, maspal() as RGBcolor)
	dim argb as RGBQUAD
	dim as integer of, y, i, skipbytes
	dim as ubyte ptr sptr

	CHECK_FRAME_8BIT(fr)

	of = write_bmp_header(f, fr->w, fr->h, 8)
	if of = -1 then exit sub

	for i = 0 to 255
		argb.rgbRed = maspal(i).r
		argb.rgbGreen = maspal(i).g
		argb.rgbBlue = maspal(i).b
		put #of, , argb
	next

	skipbytes = 4 - (fr->w mod 4)
	if skipbytes = 4 then skipbytes = 0
	sptr = fr->image + (fr->h - 1) * fr->pitch
	for y = fr->h - 1 to 0 step -1
		'put is possibly the most screwed up FB builtin; the use of the fput wrapper soothes the soul
		fput(of, , sptr, fr->w) 'equivalent to "put #of, , *sptr, fr->w"
		sptr -= fr->pitch
		'write some interesting dummy data
		fput(of, , fr->image, skipbytes)
	next

	close #of
end sub

sub frame_export_bmp4 (f as string, byval fr as Frame Ptr, maspal() as RGBcolor, byval pal as Palette16 ptr)
	dim argb as RGBQUAD
	dim as integer of, x, y, i, skipbytes
	dim as ubyte ptr sptr
	dim as ubyte pix

	CHECK_FRAME_8BIT(fr)

	of = write_bmp_header(f, fr->w, fr->h, 4)
	if of = -1 then exit sub

	for i = 0 to 15
		argb.rgbRed = maspal(pal->col(i)).r
		argb.rgbGreen = maspal(pal->col(i)).g
		argb.rgbBlue = maspal(pal->col(i)).b
		put #of, , argb
	next

	skipbytes = 4 - ((fr->w / 2) mod 4)
	if skipbytes = 4 then skipbytes = 0
	sptr = fr->image + (fr->h - 1) * fr->pitch
	for y = fr->h - 1 to 0 step -1
		for x = 0 to fr->w - 1
			if (x and 1) = 0 then
				pix = sptr[x] shl 4
			else
				pix or= sptr[x]
				put #of, , pix
			end if
		next
		if fr->w mod 2 then
			put #of, , pix
		end if
		sptr -= fr->pitch
		'write some interesting dummy data
		fput(of, , fr->image, skipbytes)
	next

	close #of
end sub

' Generic 4/8/24-bit BMP export
sub frame_export_bmp (fname as string, fr as Frame ptr, maspal() as RGBcolor, byval pal as Palette16 ptr = NULL)
	if pal then
		frame_export_bmp4 fname, fr, maspal(), pal
	elseif fr->surf then
		' todo: 8-bit surfaces
		surface_export_bmp24 fname, fr->surf
	else
		frame_export_bmp8 fname, fr, maspal()
	end if
end sub

'Creates a new file and writes the bmp headers to it.
'Returns a file handle, or -1 on error.
private function write_bmp_header(filen as string, w as integer, h as integer, bitdepth as integer) as integer
	dim header as BITMAPFILEHEADER
	dim info as BITMAPINFOHEADER

	dim as integer of, imagesize, imageoff

	imagesize = ((w * bitdepth + 31) \ 32) * 4 * h
	imageoff = 54
	if bitdepth <= 8 then
		imageoff += (1 shl bitdepth) * 4
	end if

	header.bfType = 19778
	header.bfSize = imageoff + imagesize
	header.bfReserved1 = 0
	header.bfReserved2 = 0
	header.bfOffBits = imageoff

	info.biSize = 40
	info.biWidth = w
	info.biHeight = h
	info.biPlanes = 1
	info.biBitCount = bitdepth
	info.biCompression = BI_RGB
	info.biSizeImage = imagesize
	info.biXPelsPerMeter = &hB12
	info.biYPelsPerMeter = &hB12
	info.biClrUsed = 1 shl bitdepth
	info.biClrImportant = 1 shl bitdepth

	if openfile(filen, for_binary + access_write, of) then  'Truncate
		debugc errError, "write_bmp_header: couldn't open " & filen
		return -1
	end if

	put #of, , header
	put #of, , info

	return of
end function

'Open a BMP file, read its headers, and return a file handle (>= 0),
'or -1 if invalid, or -2 if unsupported.
'Only 1, 4, 8, 24, and 32 bit BMPs are accepted
'Afterwards, the file is positioned at the start of the palette, if there is one
function open_bmp_and_read_header(bmp as string, byref header as BITMAPFILEHEADER, byref info as BITMAPV3INFOHEADER) as integer
	dim bf as integer
	if openfile(bmp, for_binary + access_read, bf) then
		debug "open_bmp_and_read_header: couldn't open " & bmp
		return -1
	end if

	get #bf, , header
	if header.bfType <> 19778 then
		close #bf
		debuginfo bmp & " is not a valid BMP file"
		return -1
	end if

	dim bisize as integer
	get #bf, , bisize
	seek #bf, seek(bf) - 4

	if biSize = 12 then
		'debuginfo "Ancient BMP2 file"
		dim info_old as BITMAPCOREHEADER
		get #bf, , info_old
		info.biSize = biSize
		info.biCompression = BI_RGB
		info.biBitCount = info_old.bcBitCount
		info.biWidth = info_old.bcWidth
		info.biHeight = info_old.bcHeight
	elseif biSize < 40 then
		close #bf
		debuginfo "Unsupported DIB header size " & biSize & " in " & bmp
		return -2
	else
		'A BITMAPINFOHEADER or one of its extensions
		get #bf, , info
		if biSize >= 56 then
			'BITMAPV3INFOHEADER or one of its extensions
			'We don't support any of those extension features but none of them are important
		elseif biSize = 52 then
			'BITMAPV2INFOHEADER, alpha bitmask doesn't exist
			info.biAlphaMask = 0
		else
			'Assumably BITMAPINFOHEADER
			info.biRedMask = 0
			info.biGreenMask = 0
			info.biBlueMask = 0
			info.biAlphaMask = 0
		end if
	end if

	if info.biClrUsed <= 0 and info.biBitCount <= 8 then
		info.biClrUsed = 1 shl info.biBitCount
	end if

	'debuginfo bmp & " header size: " & bisize & " size: " & info.biWidth & "*" & info.biHeight & " bitdepth: " & info.biBitCount & " compression: " & info.biCompression & " colors: " & info.biClrUsed

	select case info.biBitCount
		case 1, 4, 8, 24, 32
		case else
			close #bf
			debuginfo "Unsupported bitdepth " & info.biBitCount & " in " & bmp
			if info.biBitCount = 2 or info.biBitcount = 16 then
				return -2
			else
				'Invalid
				return -1
			end if
	end select

	if (info.biCompression = BI_RLE4 and info.biBitCount <> 4) or (info.biCompression = BI_RLE8 and info.biBitCount <> 8) then
		close #bf
		debuginfo "Invalid compression scheme " & info.biCompression & " in " & info.biBitCount & "bpp BMP " & bmp
		return -1
	end if

	if info.biCompression = BI_BITFIELDS and info.biBitCount = 32 then
		'16 bit (but not 24 bit) BMPs can also use BI_BITFIELDS, but we don't support them.
		'Check whether the bitmasks are simple 8 bit masks, aside from the alpha
		'mask, which can be 0 (not present)
		if decode_bmp_bitmask(info.biRedMask) = -1 or _
		   decode_bmp_bitmask(info.biGreenMask) = -1 or _
		   decode_bmp_bitmask(info.biBlueMask) = -1 or _
		   (info.biAlphaMask <> 0 and decode_bmp_bitmask(info.biAlphaMask) = -1) then
			close #bf
			debuginfo "Unsupported BMP RGBA bitmasks " & _
			     HEX(info.biRedMask) & " " & _
			     HEX(info.biGreenMask) & " " & _
			     HEX(info.biBlueMask) & " " & _
			     HEX(info.biAlphaMask) & _
			     " in 32-bit " & bmp
			return -2
		end if
	elseif info.biCompression <> BI_RGB and info.biCompression <> BI_RLE4 and info.biCompression <> BI_RLE8 then
		close #bf
		debuginfo "Unsupported BMP compression scheme " & info.biCompression & " in " & info.biBitCount & "-bit BMP " & bmp
		return -2
	end if

	if info.biHeight < 0 then
		'A negative height indicates that the image is not stored upside-down. Unimplemented
		close #bf
		debuginfo "Unsupported non-flipped image in " & bmp
		return -2
	end if

	'Seek to palette
	'(some extra data might sit between the header and the palette only if the compression is BI_BITFIELDS
	seek #bf, 1 + sizeof(BITMAPFILEHEADER) + biSize

	return bf
end function

'Loads any supported .bmp file as a Surface, returning NULL on error.
'always_32bit: load paletted BMPs as 32 bit Surfaces instead of 8-bit ones
'(in the latter case, you have to load the palette yourself).
'The alpha channel if any is ignored
function surface_import_bmp(bmp as string, always_32bit as bool) as Surface ptr
	dim header as BITMAPFILEHEADER
	dim info as BITMAPV3INFOHEADER
	dim bf as integer

	bf = open_bmp_and_read_header(bmp, header, info)
	if bf <= -1 then return 0

	'navigate to the beginning of the bitmap data
	seek #bf, header.bfOffBits + 1

	dim ret as Surface ptr

	if info.biBitCount < 24 then
		dim paletted as Frame ptr
		paletted = frame_import_bmp_raw(bmp)
		if paletted then
			if always_32bit then
				dim bmppal(255) as RGBcolor
				loadbmppal(bmp, bmppal())
				' Convert it to 32bit
				ret = frame_to_surface32(paletted, bmppal())
			else
				' Keep 8-bit. We don't load the palette
				gfx_surfaceCreateFrameView(paletted, @ret)  'Increments refcount
			end if
			frame_unload @paletted
		end if
	else
		gfx_surfaceCreate(info.biWidth, info.biHeight, SF_32bit, SU_Staging, @ret)
		if info.biBitCount = 24 then
			loadbmp24(bf, ret)
		elseif info.biBitCount = 32 then
			loadbmp32(bf, ret, info)
		end if
	end if

	close #bf
	return ret
end function

'Loads and palettises the 24-bit or 32-bit bitmap BMP, mapped to palette pal().
'If there is an alpha channel, fully transparent pixels are mapped to index 0.
function frame_import_bmp24_or_32(bmp as string, pal() as RGBcolor, options as QuantizeOptions = TYPE(0, -1)) as Frame ptr
	dim surf as Surface ptr
	surf = surface_import_bmp(bmp, YES)
	if surf = NULL then return NULL
	return quantize_surface(surf, pal(), options)
end function

'Loads any bmp file as an (optionally transparent) 8-bit Frame (ie. with no Palette16),
'remapped to the given master palette; NULL on error.
'24 and 32 bit BMPs will have RGB pixels equal to the 'transparency' color (transparency.a should be 0)
'mapped to masterpal() index 0 (by default nothing); 'keep_col0' is ignored.
'Also, in 32 bit BMPs with an alpha channel, fully transparent pixels are mapped to index 0.
'8-or-fewer-bit BMPs get palette index 0 mapped to color 0 if 'keep_col0' is true,
'otherwise they have no color 0 pixels; 'transparency' is ignored.
function frame_import_bmp_as_8bit(bmpfile as string, masterpal() as RGBcolor, keep_col0 as bool = YES, byval transparency as RGBcolor = TYPE(-1)) as Frame ptr
	dim info as BITMAPV3INFOHEADER

	if bmpinfo(bmpfile, info) <> 2 then
		' Unreadable, invalid, or unsupported
		return NULL
	end if

	if info.biBitCount <= 8 then
		dim ret as Frame ptr

		ret = frame_import_bmp_raw(bmpfile)
		if ret = NULL then return NULL

		' Drop the palette, remapping to the master palette
		' (Can't use frame_draw, since we have an array instead of a Palette16)
		dim palindices(255) as integer
		convertbmppal(bmpfile, masterpal(), palindices(), 1)
		if keep_col0 then
			palindices(0) = 0
		end if
		for y as integer = 0 to ret->h - 1
			dim pixptr as ubyte ptr = @FRAMEPIXEL(0, y, ret)
			for x as integer = 0 to ret->w - 1
				pixptr[x] = palindices(pixptr[x])
			next
		next

		return ret
	else
		dim options as QuantizeOptions = (1, transparency)
		return frame_import_bmp24_or_32(bmpfile, masterpal(), options)
	end if
end function

sub bitmap2pal (bmp as string, pal() as RGBcolor)
'loads the 24/32-bit 16x16 palette bitmap bmp into palette pal()
'so, pixel (0,0) holds colour 0, (0,1) has colour 16, and (15,15) has colour 255
	dim header as BITMAPFILEHEADER
	dim info as BITMAPV3INFOHEADER
	dim col as RGBTRIPLE
	dim bf as integer
	dim dummy as ubyte
	dim as integer w, h

	bf = open_bmp_and_read_header(bmp, header, info)
	if bf <= -1 then exit sub

	if info.biBitCount < 24 OR info.biWidth <> 16 OR info.biHeight <> 16 then
		close #bf
		debug "bitmap2pal should not have been called!"
		exit sub
	end if

	'navigate to the beginning of the bitmap data
	seek #bf, header.bfOffBits + 1

	for h = 15 to 0 step -1
		for w = 0 to 15
			'read the data
			get #bf, , col
			pal(h * 16 + w).r = col.rgbtRed
			pal(h * 16 + w).g = col.rgbtGreen
			pal(h * 16 + w).b = col.rgbtBlue
		next
		if info.biBitCount = 32 then
			get #bf, , dummy
		end if
	next

	close #bf
end sub

function frame_import_bmp_raw(bmp as string) as Frame ptr
'load a 1-, 4- or 8-bit .BMP, ignoring the palette
	dim header as BITMAPFILEHEADER
	dim info as BITMAPV3INFOHEADER
	dim bf as integer
	dim ret as frame ptr

	bf = open_bmp_and_read_header(bmp, header, info)
	if bf <= -1 then return 0

	if info.biBitCount > 8 then
		close #bf
		debugc errPromptBug, "frame_import_bmp_raw should not have been called!"
		return 0
	end if

	'use header offset to get to data
	seek #bf, header.bfOffBits + 1

	ret = frame_new(info.biWidth, info.biHeight, , YES)

	if info.biBitCount = 1 then
		loadbmp1(bf, ret)
	elseif info.biBitCount = 4 then
		'call one of two loaders depending on compression
		if info.biCompression = BI_RGB then
			loadbmp4(bf, ret)
		elseif info.biCompression = BI_RLE4 then
			frame_clear(ret)
			loadbmprle4(bf, ret)
		else
			debug "frame_import_bmp_raw should not have been called, bad 4-bit compression"
		end if
	else
		if info.biCompression = BI_RGB then
			loadbmp8(bf, ret)
		elseif info.biCompression = BI_RLE8 then
			frame_clear(ret)
			loadbmprle8(bf, ret)
		else
			debug "frame_import_bmp_raw should not have been called, bad 8-bit compression"
		end if
	end if

	close #bf
	return ret
end function

'Given a mask with 8 consecutive bits such as &hff00 returns the number of zero
'bits to the right of the bits. Returns -1 if the mask isn't of this form.
private function decode_bmp_bitmask(mask as uint32) as integer
	for shift as integer = 0 to 24
		if mask shr shift = &hFF then
			return shift
		end if
	next
	return -1
end function

'Takes an open file handle pointing at start of pixel data and an already sized Surface to load into
private sub loadbmp32(byval bf as integer, byval surf as Surface ptr, infohd as BITMAPV3INFOHEADER)
	dim bitspix as uint32
	dim quadpix as RGBQUAD
	dim sptr as RGBcolor ptr
	dim tempcol as RGBcolor
	dim as integer rshift, gshift, bshift, ashift
	tempcol.a = 255  'Opaque

	if infohd.biCompression = BI_BITFIELDS then
		' The bitmasks have already been verified to be supported, except
		' alpha might be missing
		rshift = decode_bmp_bitmask(infohd.biRedMask)
		gshift = decode_bmp_bitmask(infohd.biGreenMask)
		bshift = decode_bmp_bitmask(infohd.biBlueMask)
		ashift = decode_bmp_bitmask(infohd.biAlphaMask)
	end if

	for y as integer = surf->height - 1 to 0 step -1
		sptr = surf->pColorData + y * surf->pitch
		for x as integer = 0 to surf->width - 1
			if infohd.biCompression = BI_BITFIELDS then
				get #bf, , bitspix
				tempcol.r = bitspix shr rshift
				tempcol.g = bitspix shr gshift
				tempcol.b = bitspix shr bshift
				if ashift <> -1 then
					tempcol.a = bitspix shr ashift
				end if
				*sptr = tempcol
			else
				'Layout of RGBQUAD and RGBcolor are the same
				get #bf, , quadpix
				*sptr = *cast(RGBcolor ptr, @quadpix)
			end if
			sptr += 1
		next
	next
end sub

'Takes an open file handle pointing at start of pixel data and an already sized Surface to load into
private sub loadbmp24(byval bf as integer, byval surf as Surface ptr)
	dim pix as RGBTRIPLE
	dim ub as ubyte
	dim sptr as RGBcolor ptr
	dim pad as integer

	'data lines are padded to 32-bit boundaries
	pad = 4 - ((surf->width * 3) mod 4)
	if pad = 4 then	pad = 0

	for y as integer = surf->height - 1 to 0 step -1
		sptr = surf->pColorData + y * surf->pitch
		for x as integer = 0 to surf->width - 1
			get #bf, , pix
			'First 3 bytes of RGBTRIPLE are the same as RGBcolor
			*sptr = *cast(RGBcolor ptr, @pix)
			sptr->a = 255
			sptr += 1
		next
		'padding to dword boundary
		for w as integer = 0 to pad-1
			get #bf, , ub
		next
	next
end sub

private sub loadbmp8(byval bf as integer, byval fr as Frame ptr)
'takes an open file handle and an already size Frame pointer, should only be called within loadbmp
	dim ub as ubyte
	dim as integer w, h
	dim sptr as ubyte ptr
	dim pad as integer

	pad = 4 - (fr->w mod 4)
	if pad = 4 then	pad = 0

	for h = fr->h - 1 to 0 step -1
		sptr = fr->image + h * fr->pitch
		for w = 0 to fr->w - 1
			'read the data
			get #bf, , ub
			*sptr = ub
			sptr += 1
		next

		'padding to dword boundary
		for w = 0 to pad-1
			get #bf, , ub
		next
	next
end sub

private sub loadbmp4(byval bf as integer, byval fr as Frame ptr)
'takes an open file handle and an already size Frame pointer, should only be called within loadbmp
	dim ub as ubyte
	dim as integer w, h
	dim sptr as ubyte ptr
	dim pad as integer

	dim numbytes as integer = (fr->w + 1) \ 2  'per line
	pad = 4 - (numbytes mod 4)
	if pad = 4 then pad = 0

	for h = fr->h - 1 to 0 step -1
		sptr = fr->image + h * fr->pitch
		for w = 0 to fr->w - 1
			if (w and 1) = 0 then
				'read the data
				get #bf, , ub
				*sptr = (ub and &hf0) shr 4
			else
				'2nd nybble in byte
				*sptr = ub and &h0f
			end if
			sptr += 1
		next

		'padding to dword boundary
		for w = 0 to pad - 1
			get #bf, , ub
		next
	next
end sub

private sub loadbmprle4(byval bf as integer, byval fr as Frame ptr)
'takes an open file handle and an already size Frame pointer, should only be called within loadbmp
	dim pix as ubyte
	dim ub as ubyte
	dim as integer w, h
	dim i as integer
	dim as ubyte bval, v1, v2

	w = 0
	h = fr->h - 1

	'read bytes until we're done
	while not eof(bf)
		'get command byte
		get #bf, , ub
		select case ub
			case 0	'special, check next byte
				get #bf, , ub
				select case ub
					case 0		'end of line
						w = 0
						h -= 1
					case 1		'end of bitmap
						exit while
					case 2 		'delta (how can this ever be used?)
						get #bf, , ub
						w = w + ub
						get #bf, , ub
						h = h + ub
					case else	'absolute mode
						for i = 1 to ub
							if i and 1 then
								get #bf, , pix
								bval = (pix and &hf0) shr 4
							else
								bval = pix and &h0f
							end if
							putpixel(fr, w, h, bval)
							w += 1
						next
						if (ub mod 4 = 1) or (ub mod 4 = 2) then
							get #bf, , ub 'pad to word bound
						end if
				end select
			case else	'run-length
				get #bf, , pix	'2 colours
				v1 = (pix and &hf0) shr 4
				v2 = pix and &h0f

				for i = 1 to ub
					if i and 1 then
						bval = v1
					else
						bval = v2
					end if
					putpixel(fr, w, h, bval)
					w += 1
				next
		end select
	wend

end sub

private sub loadbmprle8(byval bf as integer, byval fr as Frame ptr)
'takes an open file handle and an already size Frame pointer, should only be called within loadbmp
	dim pix as ubyte
	dim ub as ubyte
	dim as integer w, h
	dim i as integer
	dim as ubyte bval

	w = 0
	h = fr->h - 1

	'read bytes until we're done
	while not eof(bf)
		'get command byte
		get #bf, , ub
		select case ub
			case 0	'special, check next byte
				get #bf, , ub
				select case ub
					case 0		'end of line
						w = 0
						h -= 1
					case 1		'end of bitmap
						exit while
					case 2 		'delta (how can this ever be used?)
						get #bf, , ub
						w = w + ub
						get #bf, , ub
						h = h + ub
					case else	'absolute mode
						for i = 1 to ub
							get #bf, , pix
							putpixel(fr, w, h, pix)
							w += 1
						next
						if ub mod 2 then
							get #bf, , ub 'pad to word boundary
						end if
				end select
			case else	'run-length
				get #bf, , pix

				for i = 1 to ub
					putpixel(fr, w, h, pix)
					w += 1
				next
		end select
	wend

end sub

private sub loadbmp1(byval bf as integer, byval fr as Frame ptr)
'takes an open file handle and an already sized Frame pointer, should only be called within loadbmp
	dim ub as ubyte
	dim as integer w, h
	dim sptr as ubyte ptr
	dim pad as integer

	dim numbytes as integer = (fr->w + 7) \ 8  'per line
	pad = 4 - (numbytes mod 4)
	if pad = 4 then	pad = 0

	for h = fr->h - 1 to 0 step -1
		sptr = fr->image + h * fr->pitch
		for w = 0 to fr->w - 1
			if (w mod 8) = 0 then
				get #bf, , ub
			end if
			*sptr = ub shr 7
			ub = ub shl 1
			sptr += 1
		next

		'padding to dword boundary
		for w = 0 to pad - 1
			get #bf, , ub
		next
	next
end sub

'Loads the palette of a 1-bit, 4-bit or 8-bit bmp into pal().
'Returns the number of bits, or 0 if the file can't be read.
function loadbmppal (f as string, pal() as RGBcolor) as integer
	dim header as BITMAPFILEHEADER
	dim info as BITMAPV3INFOHEADER
	dim col3 as RGBTRIPLE
	dim col4 as RGBQUAD
	dim bf as integer
	dim i as integer

	bf = open_bmp_and_read_header(f, header, info)
	if bf <= -1 then return 0

	for i = 0 to ubound(pal)
		pal(i).r = 0
		pal(i).g = 0
		pal(i).b = 0
	next

	'debug "loadbmppal(" & f & "): table at " & (seek(bf) - 1) & " = " & hex(seek(bf) - 1)
	if info.biBitCount <= 8 then
		for i = 0 to (1 shl info.biBitCount) - 1
			if info.biSize = 12 then  'BITMAPCOREHEADER
				get #bf, , col3
				pal(i).r = col3.rgbtRed
				pal(i).g = col3.rgbtGreen
				pal(i).b = col3.rgbtBlue
			else
				get #bf, , col4
				pal(i).r = col4.rgbRed
				pal(i).g = col4.rgbGreen
				pal(i).b = col4.rgbBlue
			end if
		next
	else
		debugc errBug, "loadbmppal shouldn't have been called!"
	end if
	close #bf
	return info.biBitCount
end function

sub convertbmppal (f as string, mpal() as RGBcolor, pal() as integer, firstindex as integer = 0)
'Find the nearest match palette mapping from a 1/4/8 bit bmp f to
'the master palette mpal(), and store it in pal(), an array of mpal() indices.
'pal() may contain initial values, used as hints which are used if an exact match.
'Pass firstindex = 1 to prevent anything from getting mapped to colour 0.
	dim bitdepth as integer
	dim cols(255) as RGBcolor

	bitdepth = loadbmppal(f, cols())
	if bitdepth = 0 then exit sub

	for i as integer = 0 to small(UBOUND(pal), (1 SHL bitdepth) - 1)
		pal(i) = nearcolor(mpal(), cols(i).r, cols(i).g, cols(i).b, firstindex, pal(i))
	next
end sub

'Returns 0 if invalid, otherwise fills 'info' and returns 1 if valid but unsupported, 2 if supported
function bmpinfo (f as string, byref info as BITMAPV3INFOHEADER) as integer
	dim header as BITMAPFILEHEADER
	dim bf as integer

	bf = open_bmp_and_read_header(f, header, info)
	if bf = -1 then return 0
	if bf = -2 then return 1
	close #bf
	return 2
end function

'Returns a non-negative integer which is 0 if both colors in a color table are the same
function color_distance(pal() as RGBcolor, byval index1 as integer, byval index2 as integer) as integer
	with pal(index1)
		dim as integer rdif, bdif, gdif
		rdif = .r - pal(index2).r
		gdif = .g - pal(index2).g
		bdif = .b - pal(index2).b
		return rdif*rdif + gdif*gdif + bdif*bdif
	end with
end function

function nearcolor(pal() as RGBcolor, byval red as ubyte, byval green as ubyte, byval blue as ubyte, byval firstindex as integer = 0, byval indexhint as integer = -1) as ubyte
'Figure out nearest palette colour in range [firstindex..255] using Euclidean distance
'A perfect match against pal(indexhint) is tried first
	dim as integer i, diff, best, save, rdif, bdif, gdif

	if indexhint > -1 and indexhint <= UBOUND(pal) and indexhint >= firstindex then
		with pal(indexhint)
			if red = .r and green = .g and blue = .b then return indexhint
		end with
	end if

	best = 1000000
	save = 0
	for i = firstindex to 255
		rdif = red - pal(i).r
		gdif = green - pal(i).g
		bdif = blue - pal(i).b
		'diff = abs(rdif) + abs(gdif) + abs(bdif)
		diff = rdif*rdif + gdif*gdif + bdif*bdif
		if diff = 0 then
			'early out on direct hit
			save = i
			exit for
		end if
		if diff < best then
			save = i
			best = diff
		end if
	next

	return save
end function

function nearcolor(pal() as RGBcolor, byval index as integer, byval firstindex as integer = 0) as ubyte
	with pal(index)
		return nearcolor(pal(), .r, .g, .b, firstindex)
	end with
end function

'Convert a 32 bit Surface to a paletted Frame.
'Frees surf.
'Only colours firstindex..255 in pal() are used.
'Any pixels with alpha=0 are mapped to 0; otherwise alpha is ignored.
'Optionally, any RGB colour matching 'transparency' gets mapped to index 0 (by default none);
'the Surface's alpha is ignored and transparency.a must be 0 or it won't be matched.
function quantize_surface(byref surf as Surface ptr, pal() as RGBcolor, options as QuantizeOptions) as Frame ptr
	if surf->format <> SF_32bit then
		showerror "quantize_surface only works on 32 bit Surfaces (bad frame_import_bmp24_or_32 call?)"
		gfx_surfaceDestroy(@surf)
		return NULL
	end if

	dim ret as Frame ptr
	ret = frame_new(surf->width, surf->height)

	dim inptr as RGBcolor ptr
	dim outptr as ubyte ptr
	for y as integer = 0 to surf->height - 1
		inptr = surf->pColorData + y * surf->pitch
		outptr = ret->image + y * ret->pitch
		for x as integer = 0 to surf->width - 1
			' Ignore alpha
			if inptr->col and &h00ffffff = options.transparency.col then
				*outptr = 0
			elseif inptr->a = 0 then
				*outptr = 0
			else
				*outptr = nearcolor(pal(), inptr->r, inptr->g, inptr->b, options.firstindex)
			end if
			inptr += 1
			outptr += 1
		next
	next
	gfx_surfaceDestroy(@surf)
	return ret
end function


'==========================================================================================
'                                           GIF
'==========================================================================================


' Create a GifPalette from either the master palette or a Palette16 mapped onto
' a master palette, as needed for calling lib/gif.bi functions directly
sub GifPalette_from_pal (byref gpal as GifPalette, masterpal() as RGBcolor, pal as Palette16 ptr = NULL)
	if pal then
		' Avoid using color 0 (transparency), which gets remapped to the nearest match
		' by using a colors 1-16 in a 32 colour palette
		gpal.bitDepth = 5
		for idx as integer = 0 to 16
			' Color 0 = 16
			dim masteridx as integer = pal->col(idx MOD 16)
			'if masteridx = 0 then
                        '        masteridx = uilook(uiBackground)
			'end if
			gpal.r(idx) = masterpal(masteridx).r
			gpal.g(idx) = masterpal(masteridx).g
			gpal.b(idx) = masterpal(masteridx).b
		next
	else
		' Again color 0 will be remapped, but with 256 colours to choose from there's likely
		' to be a good match
		gpal.bitDepth = 8
		for idx as integer = 0 to 255
			gpal.r(idx) = masterpal(idx).r
			gpal.g(idx) = masterpal(idx).g
			gpal.b(idx) = masterpal(idx).b
		next
	end if
end sub

' Output a single-frame .gif. Ignores mask.
sub frame_export_gif (fr as Frame Ptr, fname as string, maspal() as RGBcolor, pal as Palette16 ptr = NULL, transparent as bool = NO)
	CHECK_FRAME_8BIT(fr)  'TODO: implement 32bit export

	dim writer as GifWriter
	dim gifpal as GifPalette
	GifPalette_from_pal gifpal, maspal(), pal
	if GifBegin(@writer, fopen(fname, "wb"), fr->w, fr->h, 0, transparent, @gifpal) = NO then
		debug "GifWriter(" & fname & ") failed"
	elseif GifWriteFrame8(@writer, fr->image, fr->w, fr->h, 0, NULL) = NO then
		debug "GifWriteFrame8 failed"
	elseif GifEnd(@writer) = NO then
		debug "GifEnd failed"
	end if
end sub


property RecordGIFState.active() as bool
	return writer.f <> NULL
end property

'Returns time delay in hundreds of a second to be used for next frame
'(We have to say how long the frame will be displayed when we write it, rather than
'just telling how long the last frame was on-screen for.)
function RecordGIFState.delay() as integer
	' Predict the time that this frame will be shown via the setwait timer.
	' But the actual next setvispage might happen after or before that
	' (if there are multiple setvispage calls before dowait).
	dim as double next_frame_time = waittime
	'next_next_frame_time = waittime + 1 / requested_framerate

	if gif_max_fps > 0 andalso next_frame_time - last_frame_end_time < 1. / gif_max_fps then
		' Wait until some more time has passed
		return 0
	end if

	dim ret as integer
	ret = (next_frame_time - last_frame_end_time) * 100
	if ret <= 0 then
		' In this case there's no point writing the frame, but this should be rare
		return 0
	end if

	' Instead of doing last_frame_end_time = waittime, this accumulates
	' the parts less than 0.01s, to avoid rounding error
	last_frame_end_time += ret * 0.01
	return ret
end function

sub start_recording_gif()
	dim gifpal as GifPalette
	' Use master() rather than actual palette (intpal()), because
	' intpal() is affected by fades. We want the master palette,
	' because that's likely to be the palette for most frames.
	GifPalette_from_pal gifpal, master()
	recordgif.fname = absolute_path(next_unused_screenshot_filename() + ".gif")
	dim file as FILE ptr = fopen(recordgif.fname, "wb")
	if GifBegin(@recordgif.writer, file, vpages(vpage)->w, vpages(vpage)->h, 6, NO, @gifpal) then
		show_overlay_message "Ctrl-F12 to stop recording", 1.
		recordgif.last_frame_end_time = timer
	else
		show_overlay_message "Can't record, GifBegin failed"
	end if
end sub

sub stop_recording_gif()
	if not recordgif.active then exit sub
	if GifEnd(@recordgif.writer) = NO then
		show_overlay_message "Recording failed"
		safekill recordgif.fname
		exit sub
	end if
	dim msg as string = "Recorded " & trimpath(recordgif.fname)

	' Compress it using gifsicle, if available
	dim gifsicle as string = find_helper_app("gifsicle")
	if len(gifsicle) then
		debuginfo "Compressing " & recordgif.fname & " with gifsicle; size before = " & filelen(recordgif.fname)
		dim handle as ProcessHandle
		handle = open_process(gifsicle, "-O2 " & escape_filename(recordgif.fname) & " -o " & escape_filename(recordgif.fname), NO, NO)
		if handle = 0 then
			debug "open_process " & gifsicle & " failed"
		else
			msg += " (Compressing...)"
		end if
		cleanup_process(@handle)
	end if

	show_overlay_message msg, 1.2
end sub

'Perform the effect of pressing Ctrl-F12: start or stop recording a gif
sub toggle_recording_gif()
	if recordgif.active then
		stop_recording_gif
	else
		start_recording_gif
	end if
end sub

private sub _gif_pitch_fail(what as string)
	debugc errPromptBug, "Can't record gif from " & what & " with extra pitch"
	'This will cause the following GifWriteFrame* call to fail
	stop_recording_gif
end sub

' Called with every frame that should be included in any ongoing gif recording
private sub gif_record_frame(fr as Frame ptr, pal() as RGBcolor)
	if recordgif.active = NO then exit sub
	dim delay as integer = recordgif.delay()
	if delay <= 0 then exit sub

	dim ret as bool
	dim bits as integer
	dim sf as Surface ptr = fr->surf
	if sf andalso sf->format = SF_32bit then
		bits = 32
		dim image as ubyte ptr = cast(ubyte ptr, sf->pColorData)
		if sf->width <> sf->pitch then _gif_pitch_fail "32-bit Surface"
		ret = GifWriteFrame(@recordgif.writer, image, sf->width, sf->height, delay, 8, NO)
	else
		' 8-bit Surface-backed Frames and regular Frames.
		bits = 8
		dim gifpal as GifPalette
		GifPalette_from_pal gifpal, pal()
		if sf andalso sf->format = SF_8bit then
			if sf->width <> sf->pitch then _gif_pitch_fail "8-bit Surface"
			ret = GifWriteFrame8(@recordgif.writer, sf->pPaletteData, sf->width, sf->height, delay, @gifpal)
		else
			if fr->w <> fr->pitch then _gif_pitch_fail "Frame"
			ret = GifWriteFrame8(@recordgif.writer, fr->image, fr->w, fr->h, delay, @gifpal)
		end if
	end if
	if ret = NO then
		' On a write failure, recordgif.active will already be set to false
		show_overlay_message "Recording failed (GifWriteFrame " & bits & ")"
		debug "GifWriteFrame failed, bits = " & bits
	end if
end sub


'==========================================================================================
'                                       Screenshots
'==========================================================================================


dim shared as string*4 screenshot_exts(...) => {".bmp", ".png", ".jpg", ".dds", ".gif"}

'Save a screenshot. fname should NOT include the extension, since the gfx backend can decide that.
'Returns the filename it was saved to, with extension
function screenshot (basename as string) as string
	dim ret as string
	if len(basename) = 0 then
		basename = next_unused_screenshot_filename()
	end if
	'try external first
	if gfx_screenshot(basename) = 0 then
		'otherwise save it ourselves
		ret = basename & ".bmp"
		frame_export_bmp(ret, vpages(getvispage), intpal())
		return ret
	end if
	' The reason for this for loop is that we don't know what extension the gfx backend
	' might save the screenshot as; have to search for it.
	for i as integer = 0 to ubound(screenshot_exts)
		ret = basename & screenshot_exts(i)
		if isfile(ret) then
			return ret
		end if
	next
end function

sub bmp_screenshot(basename as string)
	'This is for when you explicitly want a bmp screenshot, and NOT the preferred
	'screenshot type used by the current gfx backend
	frame_export_bmp(basename & ".bmp", vpages(getvispage), intpal())
end sub

' Find an available screenshot name in the current directory.
' Returns filename without extension, and ensures it doesn't collide regardless of the
' extension selected from screenshot_extns.
private function next_unused_screenshot_filename() as string
	static search_start as integer
	static search_gamename as string

	dim as string ret
	dim as string gamename = trimextension(trimpath(sourcerpg))
	if gamename = "" then
		' If we haven't loaded a game yet
		gamename = "ohrrpgce"
	end if

	' Reset search_start counter if needed
	if search_gamename <> gamename then
		search_gamename = gamename
		search_start = 0
	end if

	for n as integer = search_start to 99999
		ret = gamename + right("0000" & n, 4)
		'checking curdir, which is export directory
		for i as integer = 0 to ubound(screenshot_exts)
			if isfile(ret + screenshot_exts(i)) then continue for, for
		next
		search_start = n
		return ret
	next
	return ret  'This won't be reached
end function

'Take a single screenshot if F12 is pressed.
'Holding down F12 takes a screenshot each frame, however besides
'the first, they're saved to the temporary directory until key repeat kicks in, and then
'moved, in order to 'debounce' F12 if you only press it for a short while.
'(Hmm, now that we can record gifs directly, it probably makes sense to remove the ability to hold F12)
'NOTE: global variables like tmpdir can change between calls, have to be lenient
private sub snapshot_check()
	static as string backlog()
	initialize_static_dynamic_array(backlog)
	' The following are just for the overlay message
	static as integer num_screenshots_taken
	static as string first_screenshot

	dim as integer n, F12bits
	dim as string shot

	F12bits = real_keyval(scF12)

	if F12bits = 0 then
		' If key repeat never occurred then delete the backlog.
		for n = 1 to ubound(backlog)
			'debug "killing " & backlog(n)
			safekill backlog(n)
		next
		redim backlog(0)
		' Tell what we did
		if num_screenshots_taken = 1 then
			show_overlay_message "Saved screenshot " & first_screenshot, 1.5
		elseif num_screenshots_taken > 1 then
			show_overlay_message "Saved " & first_screenshot & " and " & (num_screenshots_taken - 1) & " more", 1.5
		end if
		num_screenshots_taken = 0
	elseif real_keyval(scCtrl) = 0 then

		if F12bits = 1 then
			' Take a screenshot, but maybe delete it later
			shot = tmpdir & get_process_id() & "_tempscreen" & ubound(backlog)
			str_array_append(backlog(), screenshot(shot))
			'debug "temp save " & backlog(ubound(backlog))
		else
			' Key repeat has kicked in, so move our backlog of screenshots to the visible location.
			for n = 1 to ubound(backlog)
				shot = next_unused_screenshot_filename() & "." & justextension(backlog(n))
				'debug "moving " & backlog(n) & " to " & shot
				os_shell_move backlog(n), shot
				num_screenshots_taken += 1
			next
			redim backlog(0)

			' Take the new screenshot
			dim temp as string = screenshot()
			'debug "saved " & temp
			if num_screenshots_taken = 0 then
				first_screenshot = trimpath(temp)
			end if
			num_screenshots_taken += 1
		end if
		'debug "screen " & shot
	end if

	' This is in case this sub is called more than once before setkeys is called.
	' Normally setkeys happens at the beginning of a tick and setvispage at the end,
	' so this does no damage.
	real_clear_newkeypress scF12
end sub


'==========================================================================================
'                                 Graphics render clipping
'==========================================================================================


'NOTE: there is only one set of clipping values, shared globally for
'all drawing operations... this is probably a bad thing, but that is how
'it works. The frame argument to setclip() is used to determine
'the allowed range of clipping values.

'Set the bounds used by various (not quite all?) video page drawing functions.
'setclip must be called to reset the clip bounds whenever the clippedframe changes, to ensure
'that they are valid (the video page dimensions might differ).
sub setclip(byval l as integer = 0, byval t as integer = 0, byval r as integer = 999999, byval b as integer = 999999, byval fr as Frame ptr = 0)
	if fr <> 0 then clippedframe = fr
	with *clippedframe
		clipl = bound(l, 0, .w) '.w valid, prevents any drawing
		clipt = bound(t, 0, .h)
		clipr = bound(r, 0, .w - 1)
		clipb = bound(b, 0, .h - 1)
	end with
end sub

'Shrinks clipping area, never grows it
sub shrinkclip(byval l as integer = 0, byval t as integer = 0, byval r as integer = 999999, byval b as integer = 999999, byval fr as Frame ptr)
	if clippedframe <> fr then
		clippedframe = fr
		clipl = 0
		clipt = 0
		clipr = 999999
		clipb = 999999
	end if
	with *clippedframe
		clipl = bound(large(clipl, l), 0, .w) '.w valid, prevents any drawing
		clipt = bound(large(clipt, t), 0, .h)
		clipr = bound(small(clipr, r), 0, .w - 1)
		clipb = bound(small(clipb, b), 0, .h - 1)
	end with
end sub

sub saveclip(byref buf as ClipState)
	buf.whichframe = clippedframe
	buf.clipr = clipr
	buf.clipl = clipl
	buf.clipt = clipt
	buf.clipb = clipb
end sub

sub loadclip(byref buf as ClipState)
	clippedframe = buf.whichframe
	clipr = buf.clipr
	clipl = buf.clipl
	clipt = buf.clipt
	clipb = buf.clipb
end sub

'Blit a Frame with setclip clipping.
'trans: draw transparently, either using ->mask if available, or otherwise use colour 0 as transparent
'warning! Make sure setclip has been called before calling this
'write_mask:
'    If the destination has a mask, sets the mask for the destination rectangle
'    equal to the mask (or color-key) for the source rectangle. Does not OR them.
private sub draw_clipped(src as Frame ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
	dim as integer startx, starty, endx, endy
	dim as integer srcoffset

	startx = x
	endx = x + src->w - 1
	starty = y
	endy = y + src->h - 1

	if startx < clipl then
		srcoffset = (clipl - startx)
		startx = clipl
	end if

	if starty < clipt then
		srcoffset += (clipt - starty) * src->pitch
		starty = clipt
	end if

	if endx > clipr then
		endx = clipr
	end if

	if endy > clipb then
		endy = clipb
	end if

	if starty > endy or startx > endx then exit sub

	blitohr(src, dest, pal, srcoffset, startx, starty, endx, endy, trans, write_mask)
end sub

' Blit a Frame with setclip clipping and scale <> 1.
private sub draw_clipped_scaled(src as Frame ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, scale as integer, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
	if src->surf <> NULL or dest->surf <> NULL then
		showerror "draw_clipped_scaled: scale " & scale & " not supported with Surface-backed Frames"
		exit sub
	end if

	dim as integer sxfrom, sxto, syfrom, syto

	sxfrom = large(clipl, x)
	sxto = small(clipr, x + (src->w * scale) - 1)

	syfrom = large(clipt, y)
	syto = small(clipb, y + (src->h * scale) - 1)

	blitohrscaled (src, dest, pal, x, y, sxfrom, syfrom, sxto, syto, trans, write_mask, scale)
end sub

' Blit a Surface with setclip clipping.
private sub draw_clipped_surf(src as Surface ptr, master_pal as RGBPalette ptr, pal as Palette16 ptr = NULL, x as integer, y as integer, trans as bool, dest as Surface ptr)

	' It's OK for the src and dest rects to have negative size or be off
	' the edge of src/dest, because gfx_surfaceCopy properly clips them.
	dim srcRect as SurfaceRect = (0, 0, src->width - 1, src->height - 1)

	if x < clipl then
		srcRect.left = clipl - x
		x = clipl
	end if

	if y < clipt then
		srcRect.top = clipt - y
		y = clipt
	end if

	dim destRect as SurfaceRect = (x, y, clipr, clipb)

	if gfx_surfaceCopy(@srcRect, src, master_pal, pal, trans, @destRect, dest) then
		debug "gfx_surfaceCopy error"
	end if
end sub


'==========================================================================================
'                                   Sprite (Frame) cache
'==========================================================================================


'not to be used outside of the sprite functions
declare sub frame_delete_members(byval f as frame ptr)
declare sub frame_freemem(byval f as frame ptr)
declare sub spriteset_freemem(byval sprset as SpriteSet ptr)
'Assumes pitch == w
declare sub frame_add_mask(byval fr as frame ptr, byval clr as bool = NO)


'The sprite cache holds Frame ptrs, which may also be Frame arrays and SpriteSets. Since
'each SpriteSet is associated with a unique Frame array, we don't need a separate cache
'for SpriteSets. SpriteSet data can be loaded after and linked to the cached Frame array
'if it was initially not loaded as a SpriteSet.

'The sprite cache, which is a HashTable (sprcache) containing all loaded sprites, is split in
'two: the A cache containing currently in-use sprites (which is not explicitly tracked), and
'the B cache holding those not in use, which is a LRU list 'sprcacheB' which holds a maximum
'of SPRCACHEB_SZ entries.
'The number/size of in-use sprites is not limited, and does not count towards the B cache
'unless COMBINED_SPRCACHE_LIMIT is defined. It should be left undefined when memory usage
'is not actually important.

'I couldn't find any algorithms for inequal cost caching so invented my own: sprite size is
'measured in 'base size' units, and instead of being added to the head of the LRU list,
'sprites are moved a number of places back from the head equal to their size. This is probably
'an unnecessary complication over LRU, but it's fun.

CONST SPRCACHE_BASE_SZ = 4096  'bytes
#IFDEF LOWMEM
 'Up to 8MB, including in-use sprites
 CONST SPRCACHEB_SZ = 2048  'in SPRITE_BASE_SZ units
 #DEFINE COMBINED_SPRCACHE_LIMIT 1
#ELSE
 'Max cache size of 16MB, but actual limit will be less due to items smaller than 4KB
 CONST SPRCACHEB_SZ = 4096  'in SPRITE_BASE_SZ units
#ENDIF


' removes a sprite from the cache, and frees it.
private sub sprite_remove_cache(byval entry as SpriteCacheEntry ptr)
	if entry->p->refcount <> 1 then
		debug "error: invalidly uncaching sprite " & entry->hashed.hash & " " & frame_describe(entry->p)
	end if
	dlist_remove(sprcacheB.generic, entry)
	hash_remove(sprcache, entry)
	entry->p->cacheentry = NULL  'help to detect double free
	frame_freemem(entry->p)
	#ifdef COMBINED_SPRCACHE_LIMIT
		sprcacheB_used -= entry->cost
	#else
		if entry->Bcached then
			sprcacheB_used -= entry->cost
		end if
	#endif
	deallocate(entry)
end sub

'Free some sprites from the end of the B cache
'Returns true if enough space was freed
private function sprite_cacheB_shrink(byval amount as integer) as bool
	sprite_cacheB_shrink = (amount <= SPRCACHEB_SZ)
	if sprcacheB_used + amount <= SPRCACHEB_SZ then exit function

	dim as SpriteCacheEntry ptr pt, prevpt
	pt = sprcacheB.last
	while pt
		prevpt = pt->cacheB.prev
		sprite_remove_cache(pt)
		if sprcacheB_used + amount <= SPRCACHEB_SZ then exit function
		pt = prevpt
	wend
end function

sub sprite_empty_cache_range(minkey as integer, maxkey as integer, leakmsg as string, freeleaks as bool = NO)
	dim iterstate as integer = 0
	dim as SpriteCacheEntry ptr pt, nextpt

	nextpt = NULL
	pt = hash_iter(sprcache, iterstate, nextpt)
	while pt
		nextpt = hash_iter(sprcache, iterstate, nextpt)
		'recall that the cache counts as a reference
		if pt->p->refcount <> 1 then
			debug "warning: " & leakmsg & pt->hashed.hash & " with " & pt->p->refcount & " references"
			if freeleaks then sprite_remove_cache(pt)
		else
			sprite_remove_cache(pt)
		end if
		pt = nextpt
	wend
end sub

'Unlike sprite_empty_cache, this reloads (in-use) sprites from file, without changing the pointers
'to them. Any sprite that's not actually in use is removed from the cache as it's unnecessary to reload.
private sub sprite_update_cache_range(minkey as integer, maxkey as integer)
	dim iterstate as integer = 0
	dim as SpriteCacheEntry ptr pt, nextpt

	nextpt = NULL
	pt = hash_iter(sprcache, iterstate, nextpt)
	while pt
		nextpt = hash_iter(sprcache, iterstate, nextpt)

		if pt->hashed.hash < minkey or pt->hashed.hash > maxkey then
			pt = nextpt
			continue while
		end if

		'recall that the cache counts as a reference
		if pt->p->refcount <> 1 then
			dim sprtype as integer = pt->hashed.hash \ SPRITE_CACHE_MULT
			dim record as integer = pt->hashed.hash mod SPRITE_CACHE_MULT
			dim newframe as Frame ptr
			newframe = frame_load_uncached(sprtype, record)

			if newframe <> NULL then
				if newframe->arraylen <> pt->p->arraylen then
					fatalerror "sprite_update_cache: wrong number of frames!"
				else
					'Transplant the data from the new Frame into the old Frame, so that no
					'pointers need to be updated. pt (the SpriteCacheEntry) doesn't need to
					'to be modified at all

					dim refcount as integer = pt->p->refcount
					dim wantmask as bool = (pt->p->mask <> NULL)
					'Remove the host's previous organs
					frame_delete_members pt->p
					'Insert the new organs
					memcpy(pt->p, newframe, sizeof(Frame) * newframe->arraylen)
					'Having removed everything from the donor, dispose of it
					Deallocate(newframe)
					'Fix the bits we just clobbered
					pt->p->cached = 1
					pt->p->refcount = refcount
					pt->p->cacheentry = pt
					if pt->p->sprset then
						'Update cross-link
						pt->p->sprset->frames = pt->p
					end if
					'Make sure we don't crash if we were using a mask (might be the wrong mask though)
					if wantmask then frame_add_mask pt->p

				end if
			end if
		else
			sprite_remove_cache(pt)
		end if
		pt = nextpt
	wend
end sub

'Reload all graphics of certain type
sub sprite_update_cache(sprtype as SpriteType)
	sprite_update_cache_range(SPRITE_CACHE_MULT * sprtype, SPRITE_CACHE_MULT * (sprtype + 1) - 1)
end sub

'Attempt to completely empty the sprite cache, detecting memory leaks
'By default, remove everything. With an argument: remove specific type
sub sprite_empty_cache(sprtype as SpriteType = sprTypeInvalid)
	if sprtype = sprTypeInvalid then
		sprite_empty_cache_range(INT_MIN, INT_MAX, "leaked sprite ")
		if sprcacheB_used <> 0 or sprcache.numitems <> 0 then
			debug "sprite_empty_cache: corruption: sprcacheB_used=" & sprcacheB_used & " items=" & sprcache.numitems
		end if
	else
		sprite_empty_cache_range(SPRITE_CACHE_MULT * sprtype, SPRITE_CACHE_MULT * (sprtype + 1) - 1, "leaked sprite ")
	end if
end sub

sub sprite_debug_cache()
	debug "==sprcache=="
	dim iterstate as integer = 0
	dim pt as SpriteCacheEntry ptr = NULL

	while hash_iter(sprcache, iterstate, pt)
		debug pt->hashed.hash & " cost=" & pt->cost & " : " & frame_describe(pt->p)
	wend

	debug "==sprcacheB== (used units = " & sprcacheB_used & "/" & SPRCACHEB_SZ & ")"
	pt = sprcacheB.first
	while pt
		debug pt->hashed.hash & " cost=" & pt->cost & " : " & frame_describe(pt->p)
		pt = pt->cacheB.next
	wend
end sub

'a sprite has no references, move it to the B cache
private sub sprite_to_B_cache(byval entry as SpriteCacheEntry ptr)
	dim pt as SpriteCacheEntry ptr

	if sprite_cacheB_shrink(entry->cost) = NO then
		'fringe case: bigger than the max cache size
		sprite_remove_cache(entry)
		exit sub
	end if

	'apply size penalty
	pt = sprcacheB.first
	dim tobepaid as integer = entry->cost
	while pt
		tobepaid -= pt->cost
		if tobepaid <= 0 then exit while
		pt = pt->cacheB.next
	wend
	dlist_insertat(sprcacheB.generic, pt, entry)
	entry->Bcached = YES
	#ifndef COMBINED_SPRCACHE_LIMIT
		sprcacheB_used += entry->cost
	#endif
end sub

' move a sprite out of the B cache
private sub sprite_from_B_cache(byval entry as SpriteCacheEntry ptr)
	dlist_remove(sprcacheB.generic, entry)
	entry->Bcached = NO
	#ifndef COMBINED_SPRCACHE_LIMIT
		sprcacheB_used -= entry->cost
	#endif
end sub

' search cache, update as required if found
private function sprite_fetch_from_cache(byval key as integer) as Frame ptr
	dim entry as SpriteCacheEntry ptr

	entry = hash_find(sprcache, key)

	if entry then
		'cachehit += 1
		if entry->Bcached then
			sprite_from_B_cache(entry)
		end if
		entry->p->refcount += 1
		return entry->p
	end if
	return NULL
end function

' adds a newly loaded frame to the cache with a given key
private sub sprite_add_cache(byval key as integer, byval p as frame ptr)
	if p = 0 then exit sub

	dim entry as SpriteCacheEntry ptr
	entry = callocate(sizeof(SpriteCacheEntry))

	entry->hashed.hash = key
	entry->p = p
	entry->cost = (p->w * p->h * p->arraylen) \ SPRCACHE_BASE_SZ + 1
	'leave entry->cacheB unlinked
	entry->Bcached = NO

	'the cache counts as a reference, but only to the head element of an array!!
	p->cached = 1
	p->refcount += 1
	p->cacheentry = entry
	hash_add(sprcache, entry)

	#ifdef COMBINED_SPRCACHE_LIMIT
		sprcacheB_used += entry->cost
	#endif
end sub


'==========================================================================================
'                                          Frames
'==========================================================================================


'Create a blank Frame or array of Frames
'By default not initialised; pass clr=YES to initialise to 0
'with_surface32: if true, create a 32-it Surface-backed Frame.
function frame_new(w as integer, h as integer, frames as integer = 1, clr as bool = NO, wantmask as bool = NO, with_surface32 as bool = NO) as Frame ptr
	if w < 1 or h < 1 or frames < 1 then
		debugc errPromptBug, "frame_new: bad size " & w & "*" & h & "*" & frames
		return 0
	end if
	if with_surface32 then
		if wantmask then
			debugc errPromptBug, "frame_new: mask and backing surface mututally exclusive"
		end if
	end if

	dim ret as frame ptr
	'this hack was Mike's idea, not mine!
	ret = callocate(sizeof(Frame) * frames)

	'no memory? shucks.
	if ret = 0 then
		debug "Could not create sprite frames, no memory"
		return 0
	end if

	dim as integer i, j
	for i = 0 to frames - 1
		with ret[i]
			'the caller to frame_new is considered to have a ref to the head; and the head to have a ref to each other elem
			'so set each refcount to 1
			.refcount = 1
			.arraylen = frames
			if i > 0 then .arrayelem = 1
			.w = w
			.h = h
			.pitch = w
			.mask = NULL
			if with_surface32 then
				if gfx_surfaceCreate(w, h, SF_32bit, SU_Staging, @.surf) then
					frame_freemem(ret)
					return NULL
				end if
				if clr then
					gfx_surfaceFill(intpal(0).col, NULL, .surf)
				end if
			else
				if clr then
					.image = callocate(.pitch * h)
					if wantmask then .mask = callocate(.pitch * h)
				else
					.image = allocate(.pitch * h)
					if wantmask then .mask = allocate(.pitch * h)
				end if

				if .image = 0 or (.mask = 0 and wantmask <> NO) then
					debug "Could not allocate sprite frames/surfaces"
					'well, I don't really see the point freeing memory, but who knows...
					frame_freemem(ret)
					return NULL
				end if
			end if
		end with
	next
	return ret
end function

'Create a frame which is a view onto part of a larger frame
'Can return a zero-size view. Seems to work, but not yet sure that all operations will work correctly on such a frame.
function frame_new_view(byval spr as Frame ptr, byval x as integer, byval y as integer, byval w as integer, byval h as integer) as Frame ptr
	dim ret as frame ptr = callocate(sizeof(Frame))

	if ret = 0 then
		debug "Could not create sprite view, no memory"
		return 0
	end if

	if x < 0 then w -= -x: x = 0
	if y < 0 then h -= -y: y = 0
	with *ret
		.w = bound(w, 0, spr->w - x)
		.h = bound(h, 0, spr->h - y)
		if x >= spr->w or y >= spr->h or .w = 0 or .h = 0 then
			'this might help to keep things slightly saner
			.w = 0
			.h = 0
		end if
		.pitch = spr->pitch

		if spr->surf then
			if gfx_surfaceCreateView(spr->surf, x, y, .w, .h, @.surf) then
				deallocate ret
				return NULL
			end if
		else
			.image = spr->image + .pitch * y + x
			if spr->mask then
				.mask = spr->mask + .pitch * y + x
			end if
		end if
		.refcount = 1
		.arraylen = 1 'at the moment not actually used anywhere on sprites with isview = 1
		.isview = 1
		'we point .base at the 'root' frame which really owns these pixel buffer(s)
		if spr->isview then
			.base = spr->base
		else
			.base = spr
		end if
		if .base->refcount <> NOREFC then .base->refcount += 1
	end with
	return ret
end function

' Returns a Frame which is backed by a Surface.
' Unload/Destroy both the Frame and the Surface: increments refcount for the Surface!
function frame_with_surface(surf as Surface ptr) as Frame ptr
	dim ret as Frame ptr = callocate(sizeof(Frame))

	'Note: normally it makes no sense to call this on a Surface that is itself
	'a view of a Frame

	surf = gfx_surfaceReference(surf)
	with *ret
		.surf = surf
		.w = surf->width
		.h = surf->height
		.pitch = surf->pitch
		'image and mask are Null
		.refcount = 1
		.arraylen = 1
	end with
	return ret
end function

' Creates an (independent) 32 bit Surface which is a copy of an unpaletted Frame.
' This is not the same as gfx_surfaceCreateFrameView, which creates a Surface which
' is just a view of a Frame (and is a temporary hack!)
function frame_to_surface32(fr as Frame ptr, masterpal() as RGBcolor, pal as Palette16 ptr = NULL) as Surface ptr
	if fr->surf then
		debug "frame_to_surface32 called on a Surface-backed Frame"
		if fr->surf->format = SF_8bit then
			showerror "Converting Frame w/ 8bit Surface to 32bit Surface unimplemented"
		end if
		return fr->surf
	end if

	dim surf as Surface ptr
	if gfx_surfaceCreate(fr->w, fr->h, SF_32bit, SU_Staging, @surf) then
		return NULL
	end if
	dim wrapper as Frame ptr  'yuck
	wrapper = frame_with_surface(surf)
	frame_draw fr, masterpal(), pal, 0, 0, , NO, wrapper
	frame_unload @wrapper
	return surf
end function

' Turn a regular Frame into a 32-bit Surface-backed Frame.
' Content is preserved.
sub frame_convert_to_32bit(fr as Frame ptr, masterpal() as RGBcolor, pal as Palette16 ptr = NULL)
	if fr->cached then
		showerror "frame_convert_to_32bit: refusing to clobber cached Frame"
		exit sub
	end if
	fr->surf = frame_to_surface32(fr, masterpal(), pal)

	deallocate(fr->image)
	fr->image = NULL
	deallocate(fr->mask)
	fr->mask = NULL
end sub

' Turn Surface-backed Frame back to a regular Frame. Content IS WIPED!
sub frame_drop_surface(fr as Frame ptr)
	if fr->surf then
		gfx_surfaceDestroy(@fr->surf)
		if fr->image = NULL then
			fr->image = callocate(fr->pitch * fr->h)
		end if
	end if
end sub

private sub frame_delete_members(byval f as frame ptr)
	if f->arrayelem then debug "can't free arrayelem!": exit sub
	for i as integer = 0 to f->arraylen - 1
		deallocate(f[i].image)
		f[i].image = NULL
		deallocate(f[i].mask)
		f[i].mask = NULL
		if f[i].surf then gfx_surfaceDestroy(@f[i].surf)
		f[i].refcount = FREEDREFC  'help to detect double free
	next
	if f->sprset then
		delete f->sprset
		f->sprset = NULL
	end if
end sub

' unconditionally frees a sprite from memory.
' You should never need to call this: use frame_unload
' Should only be called on the head of an array (and not a view, obv)!
' Warning: not all code calls frame_freemem to free sprites! Grrr!
private sub frame_freemem(byval f as frame ptr)
	if f = 0 then exit sub
	frame_delete_members f
	deallocate(f)
end sub

'Public:
' Loads a 4-bit or 8-bit sprite/backdrop/tileset from the appropriate game lump, *with caching*.
' For 4-bit sprites it will return a pointer to the first frame, and subsequent frames
' will be immediately after it in memory. (This is a hack, and will probably be removed)
' For tilesets, the tileset will already be reordered as needed.
function frame_load(sprtype as SpriteType, record as integer) as Frame ptr
	dim key as integer = sprtype * SPRITE_CACHE_MULT + record
	dim ret as Frame ptr = sprite_fetch_from_cache(key)
	if ret then return ret
	ret = frame_load_uncached(sprtype, record)
	if ret then sprite_add_cache(key, ret)
	return ret
end function

private function graphics_file(extn as string) as string
	if len(game) = 0 then
		' Haven't loaded a game, fallback to the engine's default graphics
		dim gfxdir as string = finddatadir("defaultgfx")
		if len(gfxdir) = 0 then
			return ""
		end if
		return gfxdir & SLASH "ohrrpgce" & extn
	end if
	return game & extn
end function

' Loads a 4-bit or 8-bit sprite/backdrop/tileset from the appropriate game lump. See frame_load.
private function frame_load_uncached(sprtype as SpriteType, record as integer) as Frame ptr
	if sprtype < 0 or sprtype > sprTypeLastLoadable or record < 0 then
		debugc errBug, "frame_load: invalid type=" & sprtype & " and rec=" & record
		return 0
	end if

	dim ret as Frame ptr
	dim starttime as double = timer

	if sprtype = sprTypeBackdrop then
		ret = frame_load_mxs(graphics_file(".mxs"), record)
	elseif sprtype = sprTypeTileset then
		dim mxs as Frame ptr
		mxs = frame_load_mxs(graphics_file(".til"), record)
		if mxs = NULL then return NULL
		ret = mxs_frame_to_tileset(mxs)
		frame_unload @mxs
	else
		with sprite_sizes(sprtype)
			'debug "loading " & sprtype & "  " & record
			'cachemiss += 1
			ret = frame_load_4bit(graphics_file(".pt" & sprtype), record, .frames, .size.w, .size.h)
		end with
	end if

	if ret then
		ret->sprset = new SpriteSet(ret)
		init_4bit_spriteset_defaults(ret->sprset, sprtype)
	end if

	debug_if_slow(starttime, 0.1, sprtype & "," & record)
	return ret
end function

' You can use this to load a .pt?-format 4-bit sprite from some non-standard location.
' No code does this. Does not use a cache.
' It will return a pointer to the first frame (of num frames), and subsequent frames
' will be immediately after it in memory. (This is a hack, and will probably be removed)
function frame_load_4bit(filen as string, rec as integer, numframes as integer, wid as integer, hei as integer) as Frame ptr
	dim ret as frame ptr

	dim frsize as integer = wid * hei / 2
	dim recsize as integer = frsize * numframes

	dim fh as integer
	if openfile(filen, for_binary + access_read, fh) then
		debugc errError, "frame_load_4bit: could not open " & filen
		return 0
	end if

	ret = frame_new(wid, hei, numframes)
	if ret = 0 then
		close #fh
		return 0
	end if

	'find the right sprite (remember, it's base-1)
	seek #fh, recsize * rec + 1

	dim framenum as integer, x as integer, y as integer, z as ubyte

	'pixels stored in columns, 2 pixels/byte
	for framenum = 0 to numframes - 1
		with ret[framenum]
			for x = 0 to wid - 1
				for y = 0 to hei - 1
					'pull up two pixels
					get #fh, , z

					'the high nybble is the first pixel
					.image[y * wid + x] = (z SHR 4)

					y += 1

					'and the low nybble is the second one
					.image[y * wid + x] = z AND 15
				next
			next
		end with
	next

	close #fh
	return ret
end function

'Appends a new "frame" child node
'TODO: Doesn't save metadata about palette or master palette
'TODO: Doesn't save mask, but we don't have any need to serialise masks at the moment
function frame_to_node(fr as Frame ptr, parent as NodePtr) as NodePtr
	dim as NodePtr frame_node, image_node
	frame_node = AppendChildNode(parent, "frame")
	AppendChildNode(frame_node, "w", fr->w)
	AppendChildNode(frame_node, "h", fr->h)

	if fr->mask then
		debug "WARNING: frame_to_node can't save masks"
	end if

	'"bits" gives the format of the "image" node; whether this Frame
	'is a 4 or 8 bit sprite is unknown (and would be stored separately)
	dim bits as integer = 8
	if fr->surf then
		if fr->surf->format = SF_32bit then
			bits = 32
		end if
	end if

	AppendChildNode(frame_node, "bits", bits)

	image_node = AppendChildNode(frame_node, "image")
	'Allocate uninitialised memory
	SetContent(image_node, NULL, fr->w * fr->h * (bits \ 8))
	dim imdata as byte ptr = GetZString(image_node)

	if fr->surf then
		dim surf as Surface ptr = fr->surf
		dim rowbytes as integer = surf->width * bits \ 8
		dim pitchbytes as integer = surf->pitch * bits \ 8
		for y as integer = 0 TO surf->height - 1
			memcpy(imdata + y * rowbytes, cast(byte ptr, surf->pRawData) + y * pitchbytes, rowbytes)
		next
	else
		for y as integer = 0 TO fr->h - 1
			memcpy(imdata + y * fr->w, fr->image + y * fr->pitch, fr->w)
		next
	end if

	return frame_node
end function

'Loads a Frame from a "frame" node (node name not enforced)
function frame_from_node(node as NodePtr) as Frame ptr
	dim as integer bitdepth = GetChildNodeInt(node, "bits", 8)
	dim as integer w = GetChildNodeInt(node, "w")
	dim as integer h = GetChildNodeInt(node, "h")
	if bitdepth <> 8 and bitdepth <> 32 then
		debugc errPromptError, "frame_from_node: Unsupported graphics bitdepth " & bitdepth
		return NULL
	end if

	dim image_node as NodePtr = GetChildByName(node, "image")
	dim imdata as ubyte ptr = GetZString(image_node)
	dim imlen as integer = GetZStringSize(image_node)
	if imdata = NULL OR imlen <> w * h * bitdepth \ 8 then
		debugc errPromptError, "frame_from_node: Couldn't load image; data missing or bad length (" & imlen & " for " & w & "*" & h & ", bitdepth=" & bitdepth & ")"
		return NULL
	end if

	dim fr as Frame ptr

	if bitdepth = 8 then
		fr = frame_new(w, h)
		if fr = NULL then
			'If the width or height was bad then an error already shown
			return NULL
		end if
		memcpy(fr->image, imdata, w * h)
	elseif bitdepth = 32 then
		dim surf as Surface ptr
		if gfx_surfaceCreate(w, h, SF_32bit, SU_Staging, @surf) then
			return NULL
		end if
		memcpy(surf->pColorData, imdata, w * h * 4)
		fr = frame_with_surface(surf)
		gfx_surfaceDestroy(@surf)
	end if
	return fr
end function

'Public:
' Releases a reference to a sprite and nulls the pointer.
' If it is refcounted, decrements the refcount, otherwise it is freed immediately.
' A note on frame arrays: you may pass around pointers to frames in it (call frame_reference
' on them) and then unload them, but no memory will be freed until the head pointer refcount reaches 0.
' The head element will have 1 extra refcount if the frame array is in the cache. Each of the non-head
' elements also have 1 refcount, indicating that they are 'in use' by the head element,
' but this is just for feel-good book keeping
' (cdecl so that it can be used in the frame ptr vector typetable)
sub frame_unload cdecl(ppfr as Frame ptr ptr)
	if ppfr = 0 then exit sub
	dim fr as Frame ptr = *ppfr
	*ppfr = 0
	if fr = 0 then exit sub

	if clippedframe = fr then clippedframe = 0
	with *fr
		if .refcount = NOREFC then
			exit sub
		end if
		if .refcount = FREEDREFC then
			debug frame_describe(fr) & " already freed!"
			exit sub
		end if
		.refcount -= 1
		if .refcount < 0 then debug frame_describe(fr) & " has refcount " & .refcount
		'if cached, can free two references at once
		if (.refcount - .cached) <= 0 then
			if .arrayelem then
				'this should not happen, because each arrayelem gets an extra refcount
				debug "arrayelem with refcount = " & .refcount
				exit sub
			end if
			if .isview then
				frame_unload @.base
				deallocate(fr)
			else
				for i as integer = 1 to .arraylen - 1
					if fr[i].refcount <> 1 then
						debug frame_describe(@fr[i]) & " array elem freed with bad refcount"
					end if
				next
				if .cached then sprite_to_B_cache(fr->cacheentry) else frame_freemem(fr)
			end if
		end if
	end with
end sub

'Takes a 320x200 Frame and produces a 20x3200 Frame in the format expected of tilesets:
'linear series of 20x20 tiles.
function mxs_frame_to_tileset(byval spr as Frame ptr) as Frame ptr
	CHECK_FRAME_8BIT(spr, NULL)

	dim tileset as Frame ptr
	tileset = frame_new(20, 20 * 160)

	dim as ubyte ptr sptr = tileset->image
	dim as ubyte ptr srcp
	dim tilex as integer
	dim tiley as integer
	dim px as integer
	dim py as integer

	for tiley = 0 to 9
		for tilex = 0 to 15
			srcp = spr->image + tilex * 20 + tiley * 320 * 20
			for py = 0 to 19
				for px = 0 to 19
					*sptr = *srcp
					sptr += 1
					srcp += 1
				next
				srcp += 320 - 20
			next
		next
	next
	return tileset
end function

function hexptr(p as any ptr) as string
	return hex(cast(intptr_t, p))
end function

function frame_describe(byval p as frame ptr) as string
	if p = 0 then return "'(null)'"
	dim temp as string
	if p->sprset then temp = p->sprset->describe()
	return "'(0x" & hexptr(p) & ") " & p->arraylen & "x" & p->w & "x" & p->h _
	       & " offset=" & p->offset.x & "," & p->offset.y  & " img=0x" & hexptr(p->image) _
	       & " msk=0x" & hexptr(p->mask) & " pitch=" & p->pitch & " cached=" & p->cached & " aelem=" _
	       & p->arrayelem & " view=" & p->isview & " base=0x" & hexptr(p->base) & " refc=" & p->refcount & "' " _
	       & temp
end function

'this is mostly just a gimmick
function frame_is_valid(byval p as frame ptr) as bool
	if p = 0 then return NO
	dim ret as bool = YES

	if p->refcount <> NOREFC and p->refcount <= 0 then ret = NO

	'this is an arbitrary test, and in theory, could cause a false-negative, but I can't concieve of 100 thousand references to the same sprite.
	if p->refcount > 100000 then ret = NO

	if p->w < 0 or p->h < 0 then ret = NO
	if p->pitch < p->w then ret = NO

	if p->surf then
		if p->image = 0 or p->mask = 0 then ret = NO
	else
		if p->image = 0 then ret = NO
	end if

	'Patterns used by Windows and Linux to scrub memory
	if cint(p->mask) = &hBAADF00D or cint(p->image) = &hBAADF00D then ret = NO
	if cint(p->mask) = &hFEEEFEEE or cint(p->image) = &hFEEEFEEE then ret = NO

	if ret = NO then
		debugc errBug, "Invalid sprite " & frame_describe(p)
		'if we get here, we are probably doomed, but this might be a recovery
		if p->cacheentry then sprite_remove_cache(p->cacheentry)
	end if
	return ret
end function

'Add a mask. NOTE: Only valid on Frames with pitch == w!
'clr: is true, blank mask, otherwise copy image
private sub frame_add_mask(byval fr as frame ptr, byval clr as bool = NO)
	CHECK_FRAME_8BIT(fr)
	if fr->mask then exit sub
	if clr = NO then
		fr->mask = allocate(fr->w * fr->h)
		'we can just copy .image in one go, since we just ensured it's contiguous
		memcpy(fr->mask, fr->image, fr->w * fr->h)
	else
		fr->mask = callocate(fr->w * fr->h)
	end if
end sub

'for a copy you intend to modify. Otherwise use frame_reference
'clr: if true, return a new blank Frame with the same size.
'note: does not copy frame arrays, only single frames
function frame_duplicate(p as Frame ptr, clr as bool = NO, addmask as bool = NO) as Frame ptr
	dim ret as Frame ptr

	if p = 0 then return 0

	if p->surf then
		if clr or addmask then
			showerror "frame_duplicate: clr/addmask unimplemented for Surfaces"
			return 0
		end if
		dim surf as Surface ptr = surface_duplicate(p->surf)
		ret = frame_with_surface(surf)
		ret->offset = p->offset
		gfx_surfaceDestroy(@surf)  'Decrement extra reference
		return ret
	end if

	ret = callocate(sizeof(frame))
	if ret = 0 then return 0

	ret->w = p->w
	ret->h = p->h
	ret->pitch = p->w
	ret->offset = p->offset
	ret->refcount = 1
	ret->image = 0
	ret->mask = 0
	ret->arraylen = 1

	if p->image then
		if clr = 0 then
			ret->image = allocate(ret->w * ret->h)
			if p->w = p->pitch then
				'a little optimisation (we know ret->w == ret->pitch)
				memcpy(ret->image, p->image, ret->w * ret->h)
			else
				for i as integer = 0 to ret->h - 1
					memcpy(ret->image + i * ret->pitch, p->image + i * p->pitch, ret->w)
				next
			end if
		else
			ret->image = callocate(ret->w * ret->h)
		end if
	end if
	if p->mask then
		if clr = 0 then
			ret->mask = allocate(ret->w * ret->h)
			if p->w = p->pitch then
				'a little optimisation (we know ret->w == ret->pitch)
				memcpy(ret->mask, p->mask, ret->w * ret->h)
			else
				for i as integer = 0 to ret->h - 1
					memcpy(ret->mask + i * ret->pitch, p->mask + i * p->pitch, ret->w)
				next
			end if
		else
			ret->mask = callocate(ret->w * ret->h)
		end if
	elseif addmask then
		frame_add_mask ret, clr
	end if

	return ret
end function

function frame_reference cdecl(byval p as frame ptr) as frame ptr
	if p = 0 then return 0
	if p->refcount = NOREFC then
		'showerror "tried to reference a non-refcounted sprite!"
	else
		p->refcount += 1
	end if
	return p
end function

' This is a convenience function to set a Frame ptr variable, CHANGING the
' Frame ptr it contains. Useful because many frame functions are not in-place.
' (Use frame_draw with trans=NO, write_mask=YES to set the contents of one Frame
' equal to another. There is no way to do so while changing the Frame size
' (it could be implemented, but only for Frames with no views onto them).
sub frame_assign cdecl(ptr_to_replace as Frame ptr ptr, new_value as Frame ptr)
	frame_unload ptr_to_replace
	*ptr_to_replace = new_value
end sub

' See frame_assign.
sub surface_assign cdecl(ptr_to_replace as Surface ptr ptr, new_value as Surface ptr)
	if *ptr_to_replace then gfx_surfaceDestroy(ptr_to_replace)
	*ptr_to_replace = new_value
end sub

' This is for the Frame ptr vector typetable. Ignore.
private sub _frame_copyctor cdecl(dest as frame ptr ptr, src as frame ptr ptr)
	*dest = frame_reference(*src)
end sub

'Public:
' draws a sprite to a page. scale must be greater than or equal to 1. if trans is false, the
' mask will be wholly ignored. Just like draw_clipped, masks are optional, otherwise use colourkey 0
' write_mask:
'    If the destination has a mask, sets the mask for the destination rectangle
'    equal to the mask (or color-key) for the source rectangle. Does not OR them.
sub frame_draw(src as frame ptr, pal as Palette16 ptr = NULL, x as RelPos, y as RelPos, scale as integer = 1, trans as bool = YES, page as integer, write_mask as bool = NO)
	frame_draw src, intpal(), pal, x, y, scale, trans, vpages(page), write_mask
end sub

sub frame_draw(src as Frame ptr, pal as Palette16 ptr = NULL, x as RelPos, y as RelPos, scale as integer = 1, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
	frame_draw src, intpal(), pal, x, y, scale, trans, dest, write_mask
end sub

' Explicitly specify the master palette to use - it is only used if the src is 8-bit
' and the dest is 32-bit.
' Also, the mask if any is ignored.
sub frame_draw overload (src as Frame ptr, masterpal() as RGBcolor, pal as Palette16 ptr = NULL, x as RelPos, y as RelPos, scale as integer = 1, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)
	if src = NULL or dest = NULL then
		showerror "trying to draw from/to null frame"
		exit sub
	end if
	if dest <> clippedframe then
		setclip , , , , dest
	end if

	x = relative_pos(x, dest->w, src->w)
	y = relative_pos(y, dest->h, src->h)
	x += src->offset.x * scale
	y += src->offset.y * scale

	frame_draw_internal src, masterpal(), pal, x, y, scale, trans, dest, write_mask
end sub

private sub frame_draw_internal(src as Frame ptr, masterpal() as RGBcolor, pal as Palette16 ptr = NULL, x as integer, y as integer, scale as integer = 1, trans as bool = YES, dest as Frame ptr, write_mask as bool = NO)

	if src->surf <> NULL or dest->surf <> NULL then
		if dest->surf = NULL then
			showerror "draw_clipped: trying to draw a Surface-backed Frame to a regular Frame"
		elseif write_mask <> NO or scale <> 1 then
			showerror "draw_clipped: write_mask and scale not supported with a Surface-backed Frame"
		end if

		dim src_surface as Surface ptr
		if src->surf then
			src_surface = src->surf
		else
			'debuginfo "frame_draw_internal: unnecessary allocation"
			if gfx_surfaceCreateFrameView(src, @src_surface) then return
		end if
		dim master_pal as RGBPalette ptr
		if src_surface->format = SF_8bit then
			' TODO: Don't do this every single call!
			if gfx_paletteFromRGB(@masterpal(0), @master_pal) then
				debug "gfx_paletteFromRGB failed"
				goto cleanup
			end if
		end if

		draw_clipped_surf src_surface, master_pal, pal, x, y, trans, dest->surf

		cleanup:
		if master_pal then
			gfx_paletteDestroy(@master_pal)
		end if
		if src->surf = NULL then
			gfx_surfaceDestroy(@src_surface)
		end if
	else
		if scale = 1 then
			draw_clipped src, pal, x, y, trans, dest
		else
			draw_clipped_scaled src, pal, x, y, scale, trans, dest, write_mask
		end if
	end if
end sub


'Return a copy which has been clipped or extended. Extended portions are filled with bgcol.
'Can also be used to scroll (does not wrap around)
function frame_resized(spr as Frame ptr, wide as integer, high as integer, shiftx as integer = 0, shifty as integer = 0, bgcol as integer = 0) as Frame ptr
	dim as Frame ptr ret
	ret = frame_new(wide, high, , NO, (spr->mask <> NULL), (spr->surf <> NULL))
	frame_clear ret, bgcol
	frame_draw spr, NULL, shiftx, shifty, 1, NO, ret, (spr->surf = NULL)  'trans=NO, write_mask=not for Surfaces
	return ret
end function

'Scale a Frame to given size. Returns a 32-bit Surface-backed Frame.
'masterpal() only used if src is 8-bit. pal can be NULL.
function frame_scaled32(src as Frame ptr, wide as integer, high as integer, masterpal() as RGBcolor, pal as Palette16 ptr = NULL) as Frame ptr
	dim as Surface ptr src_surface, temp
	if src->surf then
		src_surface = src->surf
	else
		src_surface = frame_to_surface32(src, masterpal(), pal)
	end if
	temp = surface_scale(src_surface, wide, high)
	if src->surf = NULL then
		gfx_surfaceDestroy(@src_surface)
	end if
	dim ret as Frame ptr = frame_with_surface(temp)
	gfx_surfaceDestroy(@temp)
	return ret
end function

'Public:
' Returns a (copy of the) sprite (any bitdepth) in the midst of a given fade out.
' tlength is the desired length of the transition (in any time units you please),
' t is the number of elasped time units. style is the specific transition.
function frame_dissolved(byval spr as frame ptr, byval tlength as integer, byval t as integer, byval style as integer) as frame ptr
	CHECK_FRAME_8BIT(spr, NULL)

	'Return a blank sprite of same size
	'(Note that Vapourise and Phase Out aren't blank on t==tlength, while others are, unless tlength=0
	if t > tlength then return frame_duplicate(spr, YES)
	'Return copy. (Actually Melt otherwise has very slight distortion on frame 0.)
	if t <= 0 then return frame_duplicate(spr)

	'by default, sprites use colourkey transparency instead of masks.
	'We could easily not use a mask here, but by using one, this function can be called on 8-bit graphics
	'too; just in case you ever want to fade out a backdrop or something?
	dim startblank as integer = (style = 8 or style = 9)
	dim cpy as frame ptr
	cpy = frame_duplicate(spr, startblank, 1)
	if cpy = 0 then return 0

	dim as integer i, j, sx, sy, tog

	select case style
		case 0 'scattered pixel dissolve
			dim prng_state as unsigned integer = cpy->w * tlength

			dim cutoff as unsigned integer = 2 ^ 20 * t / (tlength - 0.5)

			for sy = 0 to cpy->h - 1
				dim mptr as ubyte ptr = @cpy->mask[sy * cpy->pitch]
				for sx = 0 to cpy->w - 1
					prng_state = (prng_state * 1103515245 + 12345)
					if (prng_state shr 12) < cutoff then
						mptr[sx] = 0
					end if
				next
			next

		case 1 'crossfade
			'interesting idea: could maybe replace all this with calls to generalised fuzzyrect
			dim m as integer = cpy->w * cpy->h * t * 2 / tlength
			dim mptr as ubyte ptr
			dim xoroff as integer = 0
			if t > tlength / 2 then
				'after halfway mark: checker whole sprite, then checker the remaining (with tog xor'd 1)
				for sy = 0 to cpy->h - 1
					mptr = cpy->mask + sy * cpy->pitch
					tog = sy and 1
					for sx = 0 to cpy->w - 1
						tog = tog xor 1
						if tog then mptr[sx] = 0
					next
				next
				xoroff = 1
				m = cpy->w * cpy->h * (t - tlength / 2) * 2 / tlength
			end if
			'checker the first m pixels of the sprite
			for sy = 0 to cpy->h - 1
				mptr = cpy->mask + sy * cpy->pitch
				tog = (sy and 1) xor xoroff
				for sx = 0 to cpy->w - 1
					tog = tog xor 1
					if tog then mptr[sx] = 0
					m -= 1
					if m <= 0 then exit for, for
				next
			next
		case 2 'diagonal vanish
			i = cpy->w * t * 2 / tlength
			j = i
			for sy = 0 to i
				j = i - sy
				if sy >= cpy->h then exit for
				for sx = 0 to j
					if sx >= cpy->w then exit for
					cpy->mask[sy * cpy->pitch + sx] = 0
				next
			next
		case 3 'sink into ground
			dim fall as integer = cpy->h * t / tlength
			for sy = cpy->h - 1 to 0 step -1
				if sy < fall then
					memset(cpy->mask + sy * cpy->pitch, 0, cpy->w)
				else
					memcpy(cpy->image + sy * cpy->pitch, cpy->image + (sy - fall) * cpy->pitch, cpy->w)
					memcpy(cpy->mask + sy * cpy->pitch, cpy->mask + (sy - fall) * cpy->pitch, cpy->w)
				end if
			next
		case 4 'squash
			for i = cpy->h - 1 to 0 step -1
				dim desty as integer = cpy->h * (t / tlength) + i * (1 - t / tlength)
				desty = bound(desty, 0, cpy->h - 1)
				if desty > i then
					memcpy(cpy->image + desty * cpy->pitch, cpy->image + i * cpy->pitch, cpy->w)
					memcpy(cpy->mask + desty * cpy->pitch, cpy->mask + i * cpy->pitch, cpy->w)
					memset(cpy->mask + i * cpy->pitch, 0, cpy->w)
				end if
			next
		case 5 'melt
			'height and meltmap are fixed point, with 8 bit fractional parts
			'(an attempt to speed up this dissolve, which is 10x slower than most of the others!)
			'the current height of each column above the base of the frame
			dim height(-1 to cpy->w) as integer
			dim meltmap(cpy->h - 1) as integer

			for i = 0 to cpy->h - 1
				'Gompertz sigmoid function, exp(-exp(-x))
				'this is very close to 1 when k <= -1.5
				'and very close to 0 when k >= 1.5
				'so decreases down to 0 with increasing i (height) and t
				'meltmap(i) = exp(-exp(-7 + 8.5*(t/tlength) + (-cpy->h + i))) * 256
				meltmap(i) = exp(-exp(-8 + 10*(t/tlength) + 6*(i/cpy->h))) * 256
			next

			dim poffset as integer = (cpy->h - 1) * cpy->pitch
			dim destoff as integer

			for sy = cpy->h - 1 to 0 step -1
				for sx = 0 to cpy->w - 1
					destoff = (cpy->h - 1 - (height(sx) shr 8)) * cpy->pitch + sx

					'if sx = 24 then
						'debug sy & " mask=" & cpy->mask[poffset + sx] & " h=" & height(sx)/256 & " dest=" & (destoff\cpy->pitch) & "   " & t/tlength
					'end if

					'potentially destoff = poffset + sx
					dim temp as integer = cpy->mask[poffset + sx]
					cpy->mask[poffset + sx] = 0
					cpy->image[destoff] = cpy->image[poffset + sx]
					cpy->mask[destoff] = temp

					if temp then
						height(sx) += meltmap(height(sx) shr 8)
					else
						'empty spaces melt quicker, for flop down of hanging swords,etc
						'height(sx) += meltmap(height(sx)) * (1 - t/tlength)
						'height(sx) += meltmap((height(sx) shr 8) + 16)
						height(sx) += meltmap(sy)
					end if
				next
				poffset -= cpy->pitch

				'mix together adjacent heights so that hanging pieces don't easily disconnect
				height(-1) = height(0)
				height(cpy->w) = height(cpy->w - 1)
				for sx = (sy mod 3) to cpy->w - 1 step 3
					height(sx) = height(sx - 1) \ 4 + height(sx) \ 2 + height(sx + 1) \ 4
				next
			next
		case 6 'vapourise
			'vapoury is the bottommost vapourised row
			dim vapoury as integer = (cpy->h - 1) * (t / tlength)
			dim vspeed as integer = large(cint(cpy->h / tlength), 1)
			for sx = 0 to cpy->w - 1
				dim chunklength as integer = randint(vspeed + 5)
				for i = -2 to 9999
					if rando() < 0.3 then exit for
				next

				dim fragy as integer = large(vapoury - large(i, 0) - (chunklength - 1), 0)
				'position to copy fragment from
				dim chunkoffset as integer = large(vapoury - (chunklength - 1), 0) * cpy->pitch + sx

				dim poffset as integer = sx
				for sy = 0 to vapoury
					if sy >= fragy and chunklength <> 0 then
						cpy->image[poffset] = cpy->image[chunkoffset]
						cpy->mask[poffset] = cpy->mask[chunkoffset]
						chunkoffset += cpy->pitch
						chunklength -= 1
					else
						cpy->mask[poffset] = 0
					end if
					poffset += cpy->pitch
				next
			next
		case 7 'phase out
			dim fall as integer = 1 + (cpy->h - 2) * (t / tlength)  'range 1 to cpy->h-1
			'blank out top of sprite
			for sy = 0 to fall - 2
				memset(cpy->mask + sy * cpy->pitch, 0, cpy->w)
			next

			for sx = 0 to cpy->w - 1
				dim poffset as integer = sx + fall * cpy->pitch

				'we stretch the two pixels at the vapour-front up some factor
				dim beamc1 as integer = -1
				dim beamc2 as integer = -1
				if cpy->mask[poffset] then beamc1 = cpy->image[poffset]
				if cpy->mask[poffset - cpy->pitch] then beamc2 = cpy->image[poffset - cpy->pitch]

				if beamc1 = -1 then continue for
				for sy = fall to large(fall - 10, 0) step -1
					cpy->image[poffset] = beamc1
					cpy->mask[poffset] = 1
					poffset -= cpy->pitch
				next
				if beamc2 = -1 then continue for
				for sy = sy to large(sy - 10, 0) step -1
					cpy->image[poffset] = beamc2
					cpy->mask[poffset] = 1
					poffset -= cpy->pitch
				next
			next
		case 8 'squeeze (horizontal squash)
			dim destx(spr->w - 1) as integer
			for sx = 0 to spr->w - 1
				destx(sx) = sx * (1 - t / tlength) + 0.5 * (spr->w - 1) * (t / tlength)
			next
			for sy = 0 to spr->h - 1
				dim destimage as ubyte ptr = cpy->image + sy * cpy->pitch
				dim destmask as ubyte ptr = cpy->mask + sy * cpy->pitch
				dim srcmask as ubyte ptr = iif(spr->mask, spr->mask, spr->image)
				dim poffset as integer = sy * cpy->pitch
				for sx = 0 to spr->w - 1
					destimage[destx(sx)] = spr->image[poffset]
					destmask[destx(sx)] = srcmask[poffset]
					poffset += 1
				next
			next
		case 9 'shrink (horizontal+vertical squash)
			dim destx(spr->w - 1) as integer
			for sx = 0 to spr->w - 1
				destx(sx) = sx * (1 - t / tlength) + 0.5 * (spr->w - 1) * (t / tlength)
			next
			for sy = 0 to spr->h - 1
				dim desty as integer = sy * (1 - t / tlength) + (spr->h - 1) * (t / tlength)
				dim destimage as ubyte ptr = cpy->image + desty * cpy->pitch
				dim destmask as ubyte ptr = cpy->mask + desty * cpy->pitch
				dim srcmask as ubyte ptr = iif(spr->mask, spr->mask, spr->image)
				dim poffset as integer = sy * cpy->pitch
				for sx = 0 to spr->w - 1
					destimage[destx(sx)] = spr->image[poffset]
					destmask[destx(sx)] = srcmask[poffset]
					poffset += 1
				next
			next
		case 10 'flicker
			dim state as integer = 0
			dim ctr as integer  'percent
			for i = 0 to t
				dim cutoff as integer = 60 * (1 - i / tlength) + 25 * (i / tlength)
				dim inc as integer = 60 * i / tlength
				ctr += inc
				if ctr > cutoff then
					i += ctr \ cutoff  'length of gaps increases
					if i > t then state = 1
					ctr = ctr mod 100
				end if
			next
			if state then frame_clear(cpy)
	end select

	return cpy
end function

function default_dissolve_time(byval style as integer, byval w as integer, byval h as integer) as integer
	'squash, vapourise, phase out, squeeze
	if style = 4 or style = 6 or style = 7 or style = 8 or style = 9 then
		return w / 5
	else
		return w / 2
	end if
end function

'Used by frame_flip_horiz and frame_flip_vert
private sub flip_image(byval pixels as ubyte ptr, byval d1len as integer, byval d1stride as integer, byval d2len as integer, byval d2stride as integer)
	for x1 as integer = 0 to d1len - 1
		dim as ubyte ptr pixelp = pixels + x1 * d1stride
		for offset as integer = (d2len - 1) * d2stride to 0 step -2 * d2stride
			dim as ubyte temp = pixelp[0]
			pixelp[0] = pixelp[offset]
			pixelp[offset] = temp
			pixelp += d2stride
		next
	next
end sub

'not-in-place isometric transformation of a pixel buffer
'dimensions/strides of source is taken from src, but srcpixels specifies the actual pixel buffer
'destorigin points to the pixel in the destination buffer where the pixel at the (top left) origin should be put
private sub transform_image(byval src as Frame ptr, byval srcpixels as ubyte ptr, byval destorigin as ubyte ptr, byval d1stride as integer, byval d2stride as integer)
	for y as integer = 0 to src->h - 1
		dim as ubyte ptr sptr = srcpixels + y * src->pitch
		dim as ubyte ptr dptr = destorigin + y * d1stride
		for x as integer = 0 to src->w - 1
			*dptr = sptr[x]
			dptr += d2stride
		next
	next
end sub

'Public:
' flips a sprite horizontally. In place: you are only allowed to do this on sprites with no other references
sub frame_flip_horiz(byval spr as frame ptr)
	if spr = 0 then exit sub
	CHECK_FRAME_8BIT(spr)

	if spr->refcount > 1 then
		debug "illegal hflip on " & frame_describe(spr)
		exit sub
	end if

	flip_image(spr->image, spr->h, spr->pitch, spr->w, 1)
	if spr->mask then
		flip_image(spr->mask, spr->h, spr->pitch, spr->w, 1)
	end if
end sub

'Public:
' flips a sprite vertically. In place: you are only allowed to do this on sprites with no other references
sub frame_flip_vert(byval spr as frame ptr)
	if spr = 0 then exit sub
	CHECK_FRAME_8BIT(spr)

	if spr->refcount > 1 then
		debug "illegal vflip on " & frame_describe(spr)
		exit sub
	end if

	flip_image(spr->image, spr->w, 1, spr->h, spr->pitch)
	if spr->mask then
		flip_image(spr->mask, spr->w, 1, spr->h, spr->pitch)
	end if
end sub

'90 degree (anticlockwise) rotation.
'Unlike flipping functions, not inplace!
function frame_rotated_90(byval spr as Frame ptr) as Frame ptr
	if spr = 0 then return NULL
	CHECK_FRAME_8BIT(spr, NULL)

	dim ret as Frame ptr = frame_new(spr->h, spr->w, 1, (spr->mask <> NULL))

	'top left corner transformed to bottom left corner
	transform_image(spr, spr->image, ret->image + ret->pitch * (ret->h - 1), 1, -ret->pitch)

	if spr->mask <> NULL then
		transform_image(spr, spr->mask, ret->mask + ret->pitch * (ret->h - 1), 1, -ret->pitch)
	end if

	return ret
end function

'270 degree (anticlockwise) rotation, ie 90 degrees clockwise.
'Unlike flipping functions, not inplace!
function frame_rotated_270(byval spr as Frame ptr) as Frame ptr
	if spr = 0 then return NULL
	CHECK_FRAME_8BIT(spr, NULL)

	dim ret as Frame ptr = frame_new(spr->h, spr->w, 1, (spr->mask <> NULL))

	'top left corner transformed to top right corner
	transform_image(spr, spr->image, ret->image + (ret->w - 1), -1, ret->pitch)

	if spr->mask <> NULL then
		transform_image(spr, spr->mask, ret->mask + (ret->w - 1), -1, ret->pitch)
	end if

	return ret
end function

'Note that we clear masks to transparent! I'm not sure if this is best (not currently used anywhere), but notice that
'frame_duplicate with clr=1 does the same
sub frame_clear(byval spr as frame ptr, byval colour as integer = 0)
	if spr->surf then
		gfx_surfaceFill(intpal(colour).col, NULL, spr->surf)
		exit sub
	end if
	if spr->image then
		if spr->w = spr->pitch then
			memset(spr->image, colour, spr->w * spr->h)
		else
			for i as integer = 0 to spr->h - 1
				memset(spr->image + i * spr->pitch, colour, spr->w)
			next
		end if
	end if
	if spr->mask then
		if spr->w = spr->pitch then
			memset(spr->mask, 0, spr->w * spr->h)
		else
			for i as integer = 0 to spr->h - 1
				memset(spr->mask + i * spr->pitch, 0, spr->w)
			next
		end if
	end if
end sub

'Warning: this code is rotting; don't assume ->mask is used, etc. Anyway the whole thing should be replaced with a memmove call or two.
' function frame_scroll(byval spr as frame ptr, byval h as integer = 0, byval v as integer = 0, byval wrap as bool = NO, byval direct as bool = NO) as frame ptr
'	CHECK_FRAME_8BIT(spr, NULL)
'
' 	dim ret as frame ptr, x as integer, y as integer
'
' 	ret = frame_clear(spr, -1)
'
' 	'first scroll horizontally
'
' 	if h <> 0 then
' 		if h > 0 then
' 			for y = 0 to spr->h - 1
' 				for x = spr->w - 1 to h step -1
' 					ret->image[y * spr->h + x] = spr->image[y * spr->h - h + x]
' 					ret->mask[y * spr->h + x] = spr->mask[y * spr->h - h + x]
' 				next
' 			next
' 			if wrap then
' 				for y = 0 to spr->h - 1
' 					for x = 0 to h - 1
' 						ret->image[y * spr->h + x] = spr->image[y * spr->h + (x + spr->w - h)]
' 						ret->mask[y * spr->h + x] = spr->mask[y * spr->h + (x + spr->w - h)]
' 					next
' 				next
' 			end if
' 		else if h < 0 then
' 			for y = 0 to spr->h - 1
' 				for x = 0 to abs(h) - 1
' 					ret->image[y * spr->h + x] = spr->image[y * spr->h - h + x]
' 					ret->mask[y * spr->h + x] = spr->mask[y * spr->h - h + x]
' 				next
' 			next
' 			if wrap then
' 				for y = 0 to spr->h - 1
' 					for x = abs(h) to spr->w - 1
' 						ret->image[y * spr->h - h + x] = spr->image[y * spr->h + x]
' 						ret->mask[y * spr->h - h + x] = spr->mask[y * spr->h + x]
' 					next
' 				next
' 			end if
' 		end if
' 	end if
'
' 	'then scroll vertically
'
' 	if v <> 0 then
'
' 	end if
'
' 	if direct then
' 		deallocate(spr->image)
' 		deallocate(spr->mask)
' 		spr->image = ret->image
' 		spr->mask = ret->mask
' 		ret->image = 0
' 		ret->mask = 0
' 		sprite_delete(@ret)
' 		return spr
' 	else
' 		return ret
' 	end if
' end function

/'
private sub grabrect(byval page as integer, byval x as integer, byval y as integer, byval w as integer, byval h as integer, ibuf as ubyte ptr, tbuf as ubyte ptr = 0)
'this isn't used anywhere anymore, was used to grab tiles from the tileset videopage before loadtileset
'maybe some possible future use?
'ibuf should be pre-allocated
	dim sptr as ubyte ptr
	dim as integer i, j, px, py, l

	if ibuf = null then exit sub
	CHECK_FRAME_8BIT(vpages(page))

	sptr = vpages(page)->image

	py = y
	for i = 0 to h-1
		px = x
		for j = 0 to w-1
			l = i * w + j
			'ignore clip rect, but check screen bounds
			if not (px < 0 or px >= vpages(page)->w or py < 0 or py >= vpages(page)->h) then
				ibuf[l] = sptr[(py * vpages(page)->pitch) + px]
				if tbuf then
					if ibuf[l] = 0 then tbuf[l] = &hff else tbuf[l] = 0
				end if
			else
				ibuf[l] = 0
				tbuf[l] = 0
			end if
			px += 1
		next
		py += 1
	next

end sub
'/


'==========================================================================================
'                                        Palette16
'==========================================================================================


'This should be replaced with a real hash
'Note that the palette cache works completely differently to the sprite cache,
'and the palette refcounting system too!

type Palette16Cache
	s as string
	p as Palette16 ptr
end type


redim shared palcache(50) as Palette16Cache

private sub Palette16_delete(byval f as Palette16 ptr ptr)
	if f = 0 then exit sub
	if *f = 0 then exit sub
	(*f)->refcount = FREEDREFC  'help detect double frees
	delete *f
	*f = 0
end sub

'Completely empty the Palette16 cache
'palettes aren't uncached either when they hit 0 references
sub Palette16_empty_cache()
	dim i as integer
	for i = 0 to ubound(palcache)
		with palcache(i)
			if .p <> 0 then
				'debug "warning: leaked palette: " & .s & " with " & .p->refcount & " references"
				Palette16_delete(@.p)
			'elseif .s <> "" then
				'debug "warning: phantom cached palette " & .s
			end if
			.s = ""
		end with
	next
end sub

function Palette16_find_cache(s as string) as Palette16Cache ptr
	dim i as integer
	for i = 0 to ubound(palcache)
		if palcache(i).s = s then return @palcache(i)
	next
	return NULL
end function

sub Palette16_add_cache(s as string, byval p as Palette16 ptr, byval fr as integer = 0)
	if p = 0 then exit sub
	if p->refcount = NOREFC then
		'sanity check
		debug "Tried to add a non-refcounted Palette16 to the palette cache!"
		exit sub
	end if

	dim as integer i, sec = -1
	for i = fr to ubound(palcache)
		with palcache(i)
			if .s = "" then
				.s = s
				.p = p
				exit sub
			elseif .p->refcount <= 0 then
				sec = i
			end if
		end with
	next

	if sec > 0 then
		Palette16_delete(@palcache(sec).p)
		palcache(sec).s = s
		palcache(sec).p = p
		exit sub
	end if

	'no room? pah.
	redim preserve palcache(ubound(palcache) * 1.3 + 5)

	Palette16_add_cache(s, p, i)
end sub

'Create a new palette which is not connected to any data file
function Palette16_new(numcolors as integer = 16) as Palette16 ptr
	dim ret as Palette16 ptr
	ret = new Palette16
	ret->numcolors = numcolors
	'--noncached palettes should be deleted when they are unloaded
	ret->refcount = NOREFC
	return ret
end function

'pal() is an array of master palette indices, to convert into a Palette16
function Palette16_new_from_indices(pal() as integer) as Palette16 ptr
	if ubound(pal) > 255 then
		fatalerror "Palette indices pal() too long!"
	end if
	dim ret as Palette16 ptr = Palette16_new(ubound(pal) + 1)
	for idx as integer = 0 to ubound(pal)
		ret->col(idx) = pal(idx)
	next
	return ret
end function

'Loads and returns a palette from the current game (resolving -1 to default palette),
'returning a blank palette if it didn't exist, or returning NULL if default_blank=NO.
'(Note that the blank palette isn't put in the cache, so if that palette is later
'added to the game, it won't auto-update.)
'autotype, spr: spriteset type and id, for default palette lookup.
function Palette16_load(num as integer, autotype as SpriteType = sprTypeInvalid, spr as integer = 0, default_blank as bool = YES) as Palette16 ptr
	dim as Palette16 ptr ret = Palette16_load(graphics_file(".pal"), num, autotype, spr)
	if ret = 0 then
		if num >= 0 AND default_blank then
			' Only bother to warn if a specific palette failed to load.
			' Avoids debug noise when default palette load fails because of a non-existant defpal file
			debug "failed to load palette " & num
		end if
		if default_blank then
			return Palette16_new()
		end if
	end if
	return ret
end function

'Loads and returns a palette from a file (resolving -1 to default palette),
'Returns NULL if the palette doesn't exist!
'autotype, spr: spriteset type and id, for default palette lookup.
function Palette16_load(fil as string, num as integer, autotype as SpriteType = sprTypeInvalid, spr as integer = 0) as Palette16 ptr
	dim starttime as double = timer
	dim hashstring as string
	dim cache as Palette16Cache ptr
	if num <= -1 then
		if autotype = sprTypeInvalid then
			return 0
		end if
		num = getdefaultpal(autotype, spr)
		if num = -1 then
			return 0
		end if
	end if
	hashstring = trimpath(fil) & "#" & num

	'debug "Loading: " & hashstring
	cache = Palette16_find_cache(hashstring)
	if cache <> 0 then
		cache->p->refcount += 1
		return cache->p
	end if

	dim fh as integer
	if openfile(fil, for_binary + access_read, fh) then return 0

	dim mag as short
	get #fh, 1, mag
	if mag = 4444 then
		' File is in new file format
		get #fh, , mag
		if num > mag then
			close #fh
			return 0
		end if

		seek #fh, 17 + 16 * num
	else
		' .pal file is still in ancient BSAVE format, with exactly 100
		' palettes. This shouldn't happen because upgrade() upgrades it.
		' Skip 7-byte BSAVE header.
		seek #fh, 8 + 16 * num
	end if

	dim ret as Palette16 ptr = Palette16_new()
	if ret = 0 then
		close #fh
		debug "Could not create palette, no memory"
		return 0
	end if

	for idx as integer = 0 to 15
		dim byt as ubyte
		get #fh, , byt
		ret->col(idx) = byt
	next

	close #fh

	ret->refcount = 1
	Palette16_add_cache(hashstring, ret)

	debug_if_slow(starttime, 0.1, fil)
	return ret
end function

sub Palette16_unload(byval p as Palette16 ptr ptr)
	if p = 0 then exit sub
	if *p = 0 then exit sub
	if (*p)->refcount = NOREFC then
		'--noncached palettes should be deleted when they are unloaded
		Palette16_delete(p)
	else
		(*p)->refcount -= 1
		'debug "unloading palette (" & ((*p)->refcount) & " more copies!)"
		'Don't delete: it stays in the cache. Unlike the sprite cache, the much simpler
		'palette cache doesn't count as a reference
	end if
	*p = 0
end sub

function Palette16_duplicate(pal as Palette16 ptr) as Palette16 ptr
	dim ret as Palette16 ptr = palette16_new()
	for i as integer = 0 to ubound(pal->col)
		ret->col(i) = pal->col(i)
	next
	return ret
end function

'update a .pal-loaded palette even while in use elsewhere.
'(Won't update localpal in a cached PrintStrState... but caching isn't implemented yet)
sub Palette16_update_cache(fil as string, byval num as integer)
	dim oldpal as Palette16 ptr
	dim hashstring as string
	dim cache as Palette16Cache ptr

	hashstring = trimpath(fil) & "#" & num
	cache = Palette16_find_cache(hashstring)

	if cache then
		oldpal = cache->p

		'force a reload, creating a temporary new palette
		cache->s = ""
		cache->p = NULL
		Palette16_load(num)
		cache = Palette16_find_cache(hashstring)

		'copy to old palette structure
		dim as integer oldrefcount = oldpal->refcount
		memcpy(oldpal, cache->p, sizeof(Palette16))
		oldpal->refcount = oldrefcount
		'this sub is silly
		Palette16_delete(@cache->p)
		cache->p = oldpal
	end if
end sub

function Palette16_describe(pal as Palette16 ptr) as string
	if pal = 0 then return "'(null)'"
	dim temp as string = "<Palette16 numcolors=" & pal->numcolors & " ref=" & pal->refcount & " "
	for idx as integer = 0 to pal->numcolors - 1
		if idx then temp &= ","
		temp &= hex(pal->col(idx))
	next
	return temp & ">"
end function



'==========================================================================================
'                            SpriteSet/Animation/SpriteState
'==========================================================================================

' Number of loops/non-forwards branches that can occur in an animation without a
' wait before it's considered to be stuck in an infinite loop.
CONST ANIMATION_LOOPLIMIT = 10


redim anim_op_names(animOpLAST) as string
anim_op_names(animOpWait) =      "wait"
anim_op_names(animOpWaitMS) =    "wait"
anim_op_names(animOpFrame) =     "frame"
anim_op_names(animOpRepeat) =    "repeat"
anim_op_names(animOpSetOffset) = "set offset"
anim_op_names(animOpRelOffset) = "add offset"

redim anim_op_fullnames(animOpLAST) as string
anim_op_fullnames(animOpWait) =      "Wait (num frames)"
anim_op_fullnames(animOpWaitMS) =    "Wait (seconds)"
anim_op_fullnames(animOpFrame) =     "Set frame"
anim_op_fullnames(animOpRepeat) =    "Repeat animation"
anim_op_fullnames(animOpSetOffset) = "Move to offset (unimp)"
anim_op_fullnames(animOpRelOffset) = "Add to offset (unimp)"

sub set_animation_framerate(ms as integer)
	' We bound to 16-200 because set_speedcontrol does the same thing
	ms_per_frame = bound(ms, 16, 200)
end sub

function ms_to_frames(ms as integer) as integer
	return large(1, INT(ms / ms_per_frame))
end function

function frames_to_ms(frames as integer) as integer
	return frames * ms_per_frame
end function


' This should only be called from within allmodex
constructor SpriteSet(frameset as Frame ptr)
	if frameset->arrayelem then fatalerror "SpriteSet needs first Frame in array"
	'redim animations(0 to -1)
	frames = frameset
	num_frames = frameset->arraylen
end constructor

' Load a spriteset from file, or return a reference if already cached.
' This increments the refcount, use spriteset_unload to decrement it, NOT 'DELETE'.
function spriteset_load(ptno as SpriteType, record as integer) as SpriteSet ptr
	' frame_load will load a Frame array with a corresponding SpriteSet
	dim frameset as Frame ptr
	frameset = frame_load(ptno, record)
	if frameset = NULL then return NULL
	return frameset->sprset
end function

' Used to decrement refcount if was loaded with spriteset_load
' (no need to call this when using frame_load and accessing Frame.sprset).
sub spriteset_unload(ss as SpriteSet ptr ptr)
	'a SpriteSet and its Frame array are never unloaded separately;
	'frame_unload is responsible for all refcounting and unloading
	if ss = NULL ORELSE *ss = NULL then exit sub
	dim temp as Frame ptr = (*ss)->frames
	frame_unload @temp
	*ss = NULL
end sub

' Increment refcount.
sub SpriteSet.reference()
	if frames then frame_reference frames
end sub

function SpriteSet.describe() as string
	return "spriteset:<" & num_frames & " frames: 0x" & hexptr(frames) _
	       & ", " & ubound(animations) & " animations>"
end function

' Searches for an animation with a certain name, or NULL if there
' are no animations with that name.
' variantname is either just the name of the animation, or the
' name plus a variant separated by a space, like "walk upleft".
' The variant is optional, and the nearest match is picked amongst animations
' which match the name:
'  - prefer variant as specified
'  - then prefer an animation with blank variant
'  - then prefer the first animation (with that name)
function SpriteSet.find_animation(variantname as string) as Animation ptr
	dim as string name, variant
	dim spacepos as integer = instr(variantname, " ")
	if spacepos then
		name = left(variantname, spacepos - 1)
		variant = mid(variantname, spacepos + 1)
	else
		name = variantname
	end if

	dim best_match as Animation ptr
	for idx as integer = 0 to ubound(animations)
		if animations(idx).name = name then
			' Right name, check how good the match is
			if animations(idx).variant = variant then
				return @animations(idx)        'Exact match
			elseif len(animations(idx).variant) then
				best_match = @animations(idx)  'Prefer nonvariant animations
			elseif best_match = NULL then
				best_match = @animations(idx)  'Otherwise, default to the first variant
			end if
		end if
	next
	return best_match
end function

' Append a new blank animation and return pointer
function SpriteSet.new_animation(name as string = "", variant as string = "") as Animation ptr
	redim preserve animations(ubound(animations) + 1)
	dim ret as Animation ptr = @animations(ubound(animations))
	ret->name = name
	ret->variant = variant
	return ret
end function


constructor Animation()
end constructor

constructor Animation(name as string, variant as string = "")
	this.name = name
	this.variant = variant
end constructor

sub Animation.append(optype as AnimOpType, arg1 as integer = 0, arg2 as integer = 0)
	redim preserve ops(ubound(ops) + 1)
	with ops(ubound(ops))
		.type = optype
		.arg1 = arg1
		.arg2 = arg2
	end with
end sub


constructor SpriteState(sprset as SpriteSet ptr)
	ss = sprset
	ss->reference()  'Inc refcount, because dec it in destructor
	frame_num = 0
end constructor

constructor SpriteState(ptno as SpriteType, record as integer)
	ss = spriteset_load(ptno, record)
	frame_num = 0
end constructor

destructor SpriteState()
	spriteset_unload @ss
end destructor

' Lookup an animation and start it. See SpriteSet.find_animation() for documentation
' of variantname (animation name plus optional variant).
' Normally an animation specifies how many times it loops (unimplemented), or ends in Repeat
' to loop forever. loopcount <> 0 overrides this, giving a fixed number of
' times to play, or < 0 to repeat forever
sub SpriteState.start_animation(variantname as string, loopcount as integer = 0)
	anim_wait = 0
	anim_step = 0
	anim_loop = loopcount
	anim_looplimit = ANIMATION_LOOPLIMIT
	anim = ss->find_animation(variantname)
end sub

function SpriteState.cur_frame() as Frame ptr
	if ss = NULL then return NULL
	if frame_num < 0 or frame_num >= ss->num_frames then return NULL
	return @ss->frames[frame_num]
end function

' Advance time until the next wait, skipping the current one, and returns number of frames that the wait was for.
' Returns -1 if not waiting, -2 on error.
function SpriteState.skip_wait() as integer
	if anim = NULL then return -2
	' Look at the current op instead of anim_wait, because it might be a wait
	' which we haven't looked at yet.
	with anim->ops(anim_step)
		if .type <> animOpWait and .type <> animOpWaitMS then
			return -1
		end if
		dim ret as integer = ms_to_frames(.arg1)
		anim_wait = ret
		if animate() = NO then ret = -2  ' Until next wait
		return ret
	end with
end function

' Advance the animation by one op.
' Returns true on success, false on an error.
' Does not check for infinite loops; caller must do that.
function SpriteState.animate_step() as bool
	if anim = NULL then return NO

	' This condition only If the animation doesn't end up looping, re
	if anim_step > ubound(anim->ops) then
		debuginfo "anim done"
		anim_looplimit -= 1
		' anim_loop = 0 means default number of loops
		if anim_loop = 0 or anim_loop = 1 then
			anim = NULL
			return YES
		end if
		if anim_loop > 0 then anim_loop -= 1
		anim_step = 0
	end if

	with anim->ops(anim_step)
		select case .type
			case animOpWait, animOpWaitMS
				' These two opcodes are identical, differing only in how
				' they are treated by the editor
				anim_wait += 1
				if anim_wait > ms_to_frames(.arg1) then
					anim_wait = 0
				else
					anim_looplimit = ANIMATION_LOOPLIMIT  'Reset
					return YES
				end if
			case animOpFrame
				if .arg1 >= ss->num_frames then
					debug "Animation '" & anim->name & "': illegal frame number " & .arg1
					anim = NULL
					return NO
				end if
				frame_num = .arg1
			case animOpRepeat
				' If a loop count was specified when playing the animation,
				' then only loop that many times, otherwise repeat forever
				if anim_loop > 0 then
					anim_loop -= 1
					if anim_loop = 0 then
						anim = NULL
						return YES
					end if
				end if
				anim_step = 0
				anim_looplimit -= 1
				return YES
			case animOpSetOffset
				offset.x = .arg1
				offset.y = .arg2
			case animOpRelOffset
				offset.x += .arg1
				offset.y += .arg2
			case else
				debug "bad animation opcode " & .type & " in '" & anim->name & "'"
				anim = NULL
				return NO
		end select
	end with
	anim_step += 1
	return YES
end function

' Advance time by one tick. True on success, false on an error/infinite loop
function SpriteState.animate() as bool
	if anim = NULL then return NO

	while anim_looplimit > 0
		if animate_step() = NO then return NO  'stop on error
		if anim_wait > 0 then return YES  'stop if waiting
	wend

	' Exceeded the loop limit
	debug "animation '" & anim->name & "' got stuck in an infinite loop"
	anim = NULL
	return NO
end function

/'
sub SpriteState.draw(x as integer, y as integer, scale as integer = 1, trans as bool = YES, page as integer)
	dim as integer realx, realy
	realx = x + offset.x
	realy = y + offset.y
	frame_draw(cur_frame(), pal, realx, realy, scale, trans, page)
end sub
'/

'==========================================================================================
'                           Platform specific wrapper functions
'==========================================================================================


sub show_virtual_keyboard()
	'Does nothing on platforms that have real keyboards
	debuginfo "show_virtual_keyboard"
	io_show_virtual_keyboard()
end sub

sub hide_virtual_keyboard()
	'Does nothing on platforms that have real keyboards
	debuginfo "hide_virtual_keyboard"
	io_hide_virtual_keyboard()
end sub

sub show_virtual_gamepad()
	'Does nothing on platforms that have real keyboards
	io_show_virtual_gamepad()
end sub

sub hide_virtual_gamepad()
	'Does nothing on platforms that have real keyboards
	io_hide_virtual_gamepad()
end sub

sub remap_android_gamepad(byval player as integer, gp as GamePadMap)
	'Does nothing on non-android non-ouya platforms
	'debuginfo "remap_android_gamepad " & gp.Ud & " " & gp.Rd & " " & gp.Dd & " " & gp.Ld & " " & gp.A & " " & gp.B & " " & gp.X & " " & gp.Y & " " & gp.L1 & " " & gp.R1 & " " & gp.L2 & " " & gp.R2
	io_remap_android_gamepad(player, gp)
end sub

sub remap_touchscreen_button (byval button_id as integer, byval ohr_scancode as integer)
	'Does nothing on platforms without touch screens
	'debuginfo "remap_android_gamepad " & button_id & " " & ohr_scancode
	io_remap_touchscreen_button(button_id, ohr_scancode)
end sub

function running_on_desktop() as bool
#IFDEF __FB_ANDROID__
	return NO
#ELSE
	return YES
#ENDIF
end function

function running_on_console() as bool
	'Currently supports OUYA, GameStick, Fire-TV
#IFDEF __FB_ANDROID__
	static cached as bool = NO
	static cached_result as bool
	if not cached then
		cached_result = io_running_on_console()
		cached = YES
	end if
	return cached_result
#ELSE
	return NO
#ENDIF
end function

function running_on_ouya() as bool
'Only use this for things that strictly require OUYA, like the OUYA store
#IFDEF __FB_ANDROID__
	static cached as bool = NO
	static cached_result as bool
	if not cached then
		cached_result = io_running_on_ouya()
		cached = YES
	end if
	return cached_result
#ELSE
	return NO
#ENDIF
end function

function running_on_mobile() as bool
#IFDEF __FB_ANDROID__
	'--return true for all Android except OUYA
	static cached as bool = NO
	static cached_result as bool
	if not cached then
		cached_result = NOT io_running_on_console()
		cached = YES
	end if
	return cached_result
#ELSE
	return NO
#ENDIF
end function

function get_safe_zone_margin () as integer
	'--returns and integer from 0 to 10 representing the percentage
	' of the screen edges reserved for TV safe zones. Only returns non-zero
	' values on backends that support this feature.
	dim margin as integer = int(gfx_get_safe_zone_margin() * 100)
	return large(0, small(10, margin))
end function

sub set_safe_zone_margin (byval margin as integer)
	'the margin argument is an integer from 0 to 10 representing
	' the percentage of the screen edges reserved for TV safe zones.
	' this has no effect on backends that don't support this feature.
	margin = bound(margin, 0, 10)
	gfx_set_safe_zone_margin(margin / 100)
end sub

function supports_safe_zone_margin () as bool
	'Returns YES if the current backend supports safe zone margins
	return gfx_supports_safe_zone_margin()
end function

sub ouya_purchase_request (dev_id as string, identifier as string, key_der as string)
	'Only works on OUYA. Should do nothing on other platforms
	debug "ouya_purchase_request for product " & identifier
	gfx_ouya_purchase_request(dev_id, identifier, key_der)
end sub

function ouya_purchase_is_ready () as bool
	'Wait until the OUYA store has replied. Always return YES on other platforms
	return gfx_ouya_purchase_is_ready()
end function

function ouya_purchase_succeeded () as bool
	'Returns YES if the OUYA purchase was completed successfully.
	'Always returns NO on other platforms
	return gfx_ouya_purchase_succeeded()
end function

sub ouya_receipts_request (dev_id as string, key_der as string)
	'Start a request for reciepts. They may take some time.
	'Does nothing if the platform is not OUYA
	gfx_ouya_receipts_request(dev_id, key_der)
end sub

function ouya_receipts_are_ready () as bool
	'Wait until the OUYA store has replied. Always return YES on other platforms
	return gfx_ouya_receipts_are_ready ()
end function

function ouya_receipts_result () as string
	'Returns a newline delimited list of OUYA product identifiers that
	'have already been purchased.
	'Always returns "" on other platforms
	return gfx_ouya_receipts_result()
end function

sub email_files(address as string, subject as string, message as string, file1 as zstring ptr = NULL, file2 as zstring ptr = NULL, file3 as zstring ptr = NULL)
	debuginfo "Emailing " & *file1 & " " & *file2 & " " & *file3 & " to " & address
	debuginfo " subject: '" & subject & "' body: '" & message & "'"
	#ifdef __FB_ANDROID__
		' Omitted files should be NULL, not "".
		if len(*file1) = 0 then file1 = NULL
		if len(*file2) = 0 then file2 = NULL
		if len(*file3) = 0 then file3 = NULL
		SDL_ANDROID_EmailFiles(address, subject, message, file1, file2, file3)
	#else
		debug "email_files only supported on Android"
	#endif
end sub
