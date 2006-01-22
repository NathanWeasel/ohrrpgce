'' 
'' music_sdl.bas - External music functions implemented in SDL.
''
'' part of OHRRPGCE - see elsewhere for license details
''

option explicit

#include music.bi
#include "SDL\SDL.bi"
#include "SDL\SDL_mixer.bi"

'extern
declare sub debug(s$)
declare sub bam2mid(infile as string, outfile as string)
declare function isfile(n$) as integer

dim shared music_on as integer = 0
'dim shared music_song as FMOD_SOUND ptr = 0 'integer = 0
'dim shared fmod as FMOD_SYSTEM ptr
'dim shared fmod_channel as FMOD_CHANNEL ptr = 0
dim shared music_vol as integer
dim shared music_paused as integer
dim shared music_song as Mix_Music ptr = NULL
dim shared orig_vol as integer = -1

'The music module needs to manage a list of temporary files to
'delete when closed, mainly for custom, so they don't get lumped
type delitem
	fname as zstring ptr
	nextitem as delitem ptr
end type

dim shared delhead as delitem ptr = null

sub music_init()	
	dim version as uinteger
	if music_on = 0 then
		dim audio_rate as integer
		dim audio_format as Uint16
		dim audio_channels as integer
		dim audio_buffers as integer
	
		' We're going to be requesting certain things from our audio
		' device, so we set them up beforehand
		audio_rate = MIX_DEFAULT_FREQUENCY
		audio_format = MIX_DEFAULT_FORMAT
		audio_channels = 2
		audio_buffers = 4096
		
		SDL_Init(SDL_INIT_VIDEO or SDL_INIT_AUDIO)
		
		if (Mix_OpenAudio(audio_rate, audio_format, audio_channels, audio_buffers)) <> 0 then
			Debug "Can't open audio"
			music_on = -1
			SDL_Quit()
			exit sub
		end if
		
		music_vol = 8
		music_on = 1
		music_paused = 0
	end if	
end sub

sub music_close()
	if music_on = 1 then
		if orig_vol > -1 then
			'restore original volume
			Mix_VolumeMusic(orig_vol)
		end if
		
		if music_song <> 0 then
			Mix_FreeMusic(music_song)
			music_song = 0
			music_paused = 0
		end if
		
		Mix_CloseAudio
		SDL_Quit
		music_on = 0
		
		if delhead <> null then
			'delete temp files
			dim ditem as delitem ptr
			dim dlast as delitem ptr
			
			ditem = delhead
			while ditem <> null
				if isfile(*(ditem->fname)) then
					kill *(ditem->fname)
				end if
				deallocate ditem->fname 'deallocate string
				dlast = ditem
				ditem = ditem->nextitem
				deallocate dlast 'deallocate delitem
			wend
			delhead = null
		end if
	end if
end sub

sub music_play(songname as string, fmt as music_format)
'would be nice if we had a routine that took the number as a param
'instead of the name, maybe abstract one into compat.bas?
	if music_on = 1 then
		songname = rtrim$(songname)	'lose any added nulls
		
		if fmt = FORMAT_BAM then
			dim midname as string
			midname = songname + ".mid"
			'check if already converted
			if isfile(midname) = 0 then
				bam2mid(songname, midname)
				'add to list of temp files
				dim ditem as delitem ptr
				if delhead = null then
					delhead = allocate(sizeof(delitem))
					ditem = delhead
				else
					ditem = delhead
					while ditem->nextitem <> null
						ditem = ditem->nextitem
					wend
					ditem->nextitem = allocate(sizeof(delitem))
					ditem = ditem->nextitem
				end if
				ditem->nextitem = null
				'allocate space for zstring
				ditem->fname = allocate(len(midname) + 1)
				*(ditem->fname) = midname 'set zstring
			end if
			songname = songname + ".mid"
			fmt = FORMAT_MIDI
		end if

		'stop current song
		if music_song <> 0 then
			Mix_FreeMusic(music_song)
			music_song = 0
			music_paused = 0
		end if

		music_song = Mix_LoadMUS(songname)
		if music_song = 0 then
			debug "Could not load song " + songname
			exit sub
		end if
		
		Mix_PlayMusic(music_song, -1)			
		music_paused = 0

		if orig_vol = -1 then
			orig_vol = Mix_VolumeMusic(-1)
		end if
					
		'dim realvol as single
		'realvol = music_vol / 15
		'FMOD_Channel_SetVolume(fmod_channel, realvol)
		if music_vol = 0 then
			Mix_VolumeMusic(0)
		else
			'add a small adjustment because 15 doesn't go into 128
			Mix_VolumeMusic((music_vol * 8) + 8)
		end if
	end if
end sub

sub music_pause()
	if music_on = 1 then
		if music_song > 0 then
			if music_paused = 0 then
				Mix_PauseMusic
				music_paused = 1
			end if
		end if
	end if
end sub

sub music_resume()
	if music_on = 1 then
		if music_song > 0 then
			Mix_ResumeMusic
			music_paused = 0
		end if
	end if
end sub

sub music_setvolume(vol as integer)
	music_vol = vol
	if music_on = 1 then
		if music_vol = 0 then
			Mix_VolumeMusic(0)
		else
			'add a small adjustment because 15 doesn't go into 128
			Mix_VolumeMusic((music_vol * 8) + 8)
		end if
	end if
end sub

function music_getvolume() as integer
	music_getvolume = music_vol
end function

sub music_fade(targetvol as integer)
'Unlike the original version, this will pause everything else while it
'fades, so make sure it doesn't take too long
	dim vstep as integer = 1
	dim i as integer
	
	if music_vol > targetvol then vstep = -1
	for i = music_vol to targetvol step vstep
		music_setvolume(i)
		sleep 10
	next	
end sub

