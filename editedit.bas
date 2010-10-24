'OHRRPGCE CUSTOM - Editor Editor
'(C) Copyright 2010 James Paige and Hamster Republic Productions
'Please read LICENSE.txt for GPL License details and disclaimer of liability
'See README.txt for code docs and apologies for crappyness of this code ;)
'Except, this module APOLOGISES FOR NOTHING!
'

#ifdef __FB_LANG__
  #if __FB_LANG__ <> "fb"
'$DYNAMIC
    Option Explicit
  #endif
#endif

#include "compat.bi"
#include "allmodex.bi"
#include "common.bi"
#include "slices.bi"
#include "customsubs.bi"
#include "loading.bi"
#include "reload.bi"
#include "reloadext.bi"

#include "editedit.bi"

'-----------------------------------------------------------------------

TYPE EEState
 state AS MenuState
 menu AS MenuDef
 indent AS INTEGER
 shift AS INTEGER
 doc AS Reload.DocPtr
 root AS Reload.NodePtr
 seek_widget AS Reload.NodePtr
 clipboard AS Reload.NodePtr
 clipboard_is AS Reload.NodePtr
 filename AS STRING
 changed AS INTEGER
END TYPE

TYPE WEState
 state AS MenuState
 menu AS MenuDef
 shift AS INTEGER
 changed AS INTEGER
END TYPE

'-----------------------------------------------------------------------

DECLARE SUB ee_refresh OVERLOAD (BYREF st AS EEState)
DECLARE SUB ee_refresh OVERLOAD (BYREF st AS EEState, BYVAL widget AS Reload.NodePtr)
DECLARE FUNCTION ee_widget_string(BYREF st AS EEState, BYVAL widget AS Reload.Nodeptr) AS STRING
DECLARE SUB ee_focus_widget(BYREF st AS EEState, BYVAL widget AS Reload.Nodeptr)
DECLARE SUB ee_export(BYREF st AS EEState)
DECLARE FUNCTION ee_browse(BYREF st AS EEState) AS INTEGER
DECLARE FUNCTION ee_load(filename AS STRING, BYREF st AS EEState) AS INTEGER
DECLARE SUB ee_save(filename AS STRING, BYREF st AS EEState)
DECLARE FUNCTION ee_okay_to_unload(BYREF st AS EEState) AS INTEGER
DECLARE SUB ee_rearrange(BYREF st AS EEState, mi AS MenuDefItem Ptr)
DECLARE SUB ee_swap_widget_up(BYVAL widget AS Reload.Nodeptr)
DECLARE SUB ee_swap_widget_down(BYVAL widget AS Reload.Nodeptr)
DECLARE SUB ee_swap_widget_left(BYVAL widget AS Reload.Nodeptr)
DECLARE SUB ee_swap_widget_right(BYVAL widget AS Reload.Nodeptr)
DECLARE SUB ee_edit_menu_item(BYREF st AS EEState, mi AS MenuDefItem Ptr)
DECLARE FUNCTION ee_edit_widget(BYREF st AS EEState, BYVAL widget AS Reload.NodePtr) AS INTEGER

DECLARE FUNCTION ee_prompt_for_widget_kind() AS STRING
DECLARE FUNCTION ee_create_widget(BYREF st AS EEState, kind AS STRING) AS Reload.NodePtr
DECLARE FUNCTION ee_container_check(BYVAL cont AS Reload.NodePtr, BYVAL widget AS Reload.NodePtr) AS INTEGER
DECLARE FUNCTION ee_widget_has_caption(BYVAL widget AS Reload.NodePtr) AS INTEGER
DECLARE FUNCTION ee_edit_widget_details(BYVAL widget AS Reload.NodePtr) AS INTEGER

DECLARE FUNCTION widget_editor(BYVAL widget AS Reload.NodePtr) AS INTEGER
DECLARE SUB widget_editor_refresh(BYREF st AS WEState, BYVAL widget AS Reload.NodePtr)

'-----------------------------------------------------------------------

SUB editor_editor()
 DIM st AS EEState
 
 st.changed = NO
 st.doc = Reload.CreateDocument()
 st.root = Reload.CreateNode(st.doc, "")
 Reload.SetRootNode(st.doc, st.root)

 st.state.pt = 0
 st.state.need_update = YES
 st.state.active = YES

 ClearMenuData st.menu
 WITH st.menu
  .anchor.x = -1
  .anchor.y = -1
  .offset.x = -160
  .offset.y = -100
  .bordersize = -4
  .align = -1
  .maxrows = 18
 END WITH
 
 setkeys
 DO
  setwait 55
  setkeys

  IF st.state.need_update THEN
   DeleteMenuItems st.menu
   st.indent = 0
   ee_refresh st
   init_menu_state st.state, st.menu
   IF st.seek_widget THEN
    ee_focus_widget st, st.seek_widget
    st.seek_widget = 0
   END IF
   st.state.need_update = NO
  END IF
  
  IF keyval(scESC) > 1 THEN
   IF ee_okay_to_unload(st) THEN EXIT DO 
  END IF
  IF keyval(scF1) > 1 THEN show_help("editor_editor")
  IF keyval(scF3) > 1 THEN
   IF ee_okay_to_unload(st) THEN
    IF ee_browse(st) THEN
     setkeys
     st.state.need_update = YES
    END IF
   END IF
  END IF
  IF keyval(scF2) > 1 THEN
   ee_export st
  END IF

  st.shift = (keyval(scLeftShift) > 0 OR keyval(scRightShift) > 0)
  
  IF st.state.pt >= 0 AND st.state.pt <= st.menu.numitems - 1 THEN
   ee_edit_menu_item st, st.menu.items[st.state.pt]
   ee_rearrange st, st.menu.items[st.state.pt]
  END IF
  
  IF NOT st.shift THEN
   usemenu st.state
  END IF

  clearpage dpage
  draw_menu st.menu, st.state, dpage
  edgeprint "F1=Help", 0, 190, uilook(uiText), dpage

  SWAP vpage, dpage
  setvispage vpage
  dowait
 LOOP

 DeleteMenuItems st.menu
 IF st.clipboard <> 0 THEN Reload.FreeNode(st.clipboard)
 Reload.FreeDocument(st.doc)
 
END SUB

'-----------------------------------------------------------------------

SUB ee_edit_menu_item(BYREF st AS EEState, mi AS MenuDefItem Ptr)
 IF mi = 0 THEN debug "ee_edit_menu_item: null mi": EXIT SUB
 DIM widget AS Reload.NodePtr
 widget = mi->dataptr
 IF widget = 0 THEN debug "ee_edit_menu_item: mi has null widget node": EXIT SUB

 IF ee_edit_widget(st, widget) THEN
  mi->caption = STRING(mi->extra(0), " ") & ee_widget_string(st, widget)
  st.changed = YES
 END IF

END SUB

FUNCTION ee_edit_widget(BYREF st AS EEState, BYVAL widget AS Reload.NodePtr) AS INTEGER
 IF widget = 0 THEN debug "ee_edit_widget: null widget" : RETURN NO

 DIM changed AS INTEGER = NO

 IF ee_widget_has_caption(widget) THEN
  DIM cap AS STRING
  cap = Reload.GetChildNodeStr(widget, "caption")
  IF strgrabber(cap, 40) THEN
   IF cap = "" THEN
    Reload.SetChildNode(widget, "caption")
   ELSE
    Reload.SetChildNode(widget, "caption", cap)
   END IF
   changed = YES
  END IF
 END IF
 
 IF keyval(scEnter) > 1 THEN
  IF ee_edit_widget_details(widget) THEN
   changed = YES
  END IF
 END IF
 
 RETURN changed
END FUNCTION

SUB ee_rearrange(BYREF st AS EEState, mi AS MenuDefItem Ptr)
 DIM widget AS Reload.Nodeptr
 widget = mi->dataptr
 
 DIM changed AS INTEGER = NO
 
 IF keyval(scInsert) > 1 THEN
  DIM kind AS STRING
  kind = ee_prompt_for_widget_kind()
  IF kind <> "" THEN
   DIM newnode AS Reload.Nodeptr
   newnode = ee_create_widget(st, kind)
   Reload.AddSiblingAfter widget, newnode
   st.seek_widget = newnode
   changed = YES
  END IF
 END IF
 
 IF keyval(scCTRL) > 0 AND st.shift THEN
  IF keyval(scC) > 1 THEN
   '--copy this widget
   IF st.clipboard <> 0 THEN Reload.FreeNode(st.clipboard)
   st.clipboard = Reload.CloneNodeTree(widget)
   st.clipboard_is = widget
   changed = YES
  END IF
  IF keyval(scV) > 1 THEN
   '--paste this widget
   IF st.clipboard <> 0 THEN
    Reload.AddSiblingAfter(widget, Reload.CloneNodeTree(st.clipboard))
    IF Reload.NodeHasAncestor(widget, st.clipboard_is) THEN st.clipboard_is = 0 'cosmetic importance only
    changed = YES
   END IF
  END IF
 END IF
 
 IF st.shift THEN
  IF keyval(scUP) > 1 THEN
   ee_swap_widget_up widget
   st.seek_widget = widget
   changed = YES
  END IF
  IF keyval(scDOWN) > 1 THEN
   ee_swap_widget_down widget
   st.seek_widget = widget
   changed = YES
  END IF
  IF keyval(scLEFT) > 1 THEN
   ee_swap_widget_left widget
   st.seek_widget = widget
   changed = YES
  END IF
  IF keyval(scRIGHT) > 1 THEN
   ee_swap_widget_right widget
   st.seek_widget = widget
   changed = YES
  END IF
 END IF
 
 IF keyval(scDelete) > 1 THEN
  IF yesno("Delete this widget?" & CHR(10) & ee_widget_string(st, widget)) THEN
   Reload.FreeNode(widget)
   changed = YES
  END IF
 END IF
 
 IF changed THEN
  st.state.need_update = YES
  st.changed = YES
 END IF
END SUB

SUB ee_swap_widget_up(BYVAL widget AS Reload.Nodeptr)
 IF widget = 0 THEN EXIT SUB
 DIM sib AS Reload.NodePtr
 sib = Reload.PrevSibling(widget, "widget")
 IF sib = 0 THEN EXIT SUB
 Reload.SwapSiblingNodes(widget, sib)
END SUB

SUB ee_swap_widget_down(BYVAL widget AS Reload.Nodeptr)
 IF widget = 0 THEN EXIT SUB
 DIM sib AS Reload.NodePtr
 sib = Reload.NextSibling(widget, "widget")
 IF sib = 0 THEN EXIT SUB
 Reload.SwapSiblingNodes(widget, sib)
END SUB

SUB ee_swap_widget_left(BYVAL widget AS Reload.Nodeptr)
 IF widget = 0 THEN EXIT SUB
 DIM parent AS Reload.NodePtr
 parent = Reload.NodeParent(widget)
 IF parent = 0 THEN EXIT SUB
 Reload.AddSiblingAfter(parent, widget)
END SUB

SUB ee_swap_widget_right(BYVAL widget AS Reload.Nodeptr)
 IF widget = 0 THEN EXIT SUB
 DIM sib AS Reload.NodePtr
 sib = Reload.PrevSibling(widget, "widget")
 IF sib = 0 THEN EXIT SUB
 IF ee_container_check(sib, widget) = NO THEN EXIT SUB
 Reload.AddChild(sib, widget)
END SUB

SUB ee_refresh (BYREF st AS EEState)
 DIM widgets_container AS Reload.NodePtr
 widgets_container = Reload.Ext.NodeByPath(st.doc, "/widgets")
 IF widgets_container = 0 THEN EXIT SUB
 DIM widget AS Reload.NodePtr
 widget = Reload.FirstChild(widgets_container, "widget")
 DO WHILE widget
  ee_refresh st, widget
  widget = Reload.NextSibling(widget, "widget")
 LOOP
END SUB

SUB ee_refresh (BYREF st AS EEState, BYVAL widget AS Reload.NodePtr)
 IF widget = 0 THEN EXIT SUB

 IF widget = 0 THEN
  EXIT SUB
 END IF

 DIM s AS STRING
 s = STRING(st.indent, " ") & ee_widget_string(st, widget)
 
 DIM index AS INTEGER
 index = append_menu_item(st.menu, s)
 
 DIM mi AS MenuDefItem Ptr
 mi = st.menu.items[index]

 mi->dataptr = widget
 mi->extra(0) = st.indent

 st.indent += 1 
 DIM chnode AS Reload.Nodeptr
 chnode = Reload.FirstChild(widget, "widget")
 DO WHILE chnode
  ee_refresh st, chnode
  chnode = Reload.NextSibling(chnode, "widget")
 LOOP
 st.indent -= 1
END SUB

FUNCTION ee_widget_string(BYREF st AS EEState, BYVAL widget AS Reload.Nodeptr) AS STRING
 IF widget = 0 THEN debug "ee_widget_string: null node" : RETURN "<null ptr>"
 DIM s AS STRING = ""
 IF widget = st.clipboard_is OR Reload.NodeHasAncestor(widget, st.clipboard_is) then s &= "*"
 s &= "<" & Reload.GetString(widget) & ">" & Reload.GetChildNodeStr(widget, "caption", "")
 RETURN s
END FUNCTION

SUB ee_focus_widget(BYREF st AS EEState, BYVAL widget AS Reload.Nodeptr)
 DIM mi AS MenuDefItem Ptr
 DIM n AS Reload.Nodeptr
 FOR i AS INTEGER = 0 TO st.menu.numitems - 1
  mi = st.menu.items[i]
  n = mi->dataptr
  IF n = widget THEN
   st.state.pt = i
   EXIT FOR
  END IF
 NEXT i
 WITH st.state
  .pt = small(.pt, .last)
  .top = bound(.top, .pt - .size, .pt)
 END WITH
END SUB

SUB ee_export(BYREF st AS EEState)
 DIM outfile AS STRING
 outfile = inputfilename("Export editor definition", "", "", "input_file_export_ee", st.filename)
 IF outfile <> "" THEN
  IF INSTR(outfile, ".") = 0 THEN outfile &= ".editor"
  ee_save outfile, st
 END IF
END SUB

FUNCTION ee_browse(BYREF st AS EEState) AS INTEGER
 DIM filename AS STRING
 filename = browse(0, "", "*.editor", "",, "browse_import_ee")
 IF filename = "" THEN RETURN NO
 RETURN ee_load(filename, st)
END FUNCTION

FUNCTION ee_load(filename AS STRING, BYREF st AS EEState) AS INTEGER
 st.filename = ""
 Reload.FreeDocument st.doc
 st.doc = Reload.LoadDocument(filename)
 IF st.doc = 0 THEN debug "load '" & filename & "' failed: null doc": RETURN NO
 st.root = Reload.DocumentRoot(st.doc)
 IF st.root = 0 THEN debug "load '" & filename & "' failed: null root node": RETURN NO
 st.filename = trimpath(filename)
 st.changed = NO
 RETURN YES
END FUNCTION

SUB ee_save(filename AS STRING, BYREF st AS EEState)
 Reload.SerializeBin(filename, st.doc)
 st.filename = trimpath(filename)
 st.changed = NO
END SUB

FUNCTION ee_okay_to_unload(BYREF st AS EEState) AS INTEGER
 IF st.changed = NO THEN RETURN YES
 DIM choice AS INTEGER
 choice = twochoice("Save your changes before exiting?", "Yes, save", "No, discard")
 SELECT CASE choice
  CASE -1: 'cancelled
   RETURN NO
  CASE 0: 'yes, save!
   ee_export st
   'but only actually allow unload if the save was confirmed
   IF st.changed = NO THEN RETURN YES
   RETURN NO
  CASE 1: 'no discard!
   RETURN YES
 END SELECT
 RETURN NO
END FUNCTION

'-----------------------------------------------------------------------
'an object oriented callback system might be better than these functions
'...maybe... maybe not worth it... Why bend over backwards to make FB
'act like something it isn't... haven't decided for sure yet.
'
'It is sort of a balancing act. Do I want to upate each of the subs and
'functions below each time I add a widget type? Or do I want to update
'a set of fake-object-oriented callbacks like the ones in slices.bas
'with their associated boilerplate? Which is more work?

FUNCTION ee_prompt_for_widget_kind() AS STRING
 DIM w(11) AS STRING
 w(0) = "int"
 w(1) = "string"
 w(2) = "label"
 w(3) = "bit"
 w(4) = "submenu"
 w(5) = "picture"
 w(6) = "item"
 w(7) = "attack"
 w(8) = "tag"
 w(9) = "tagcheck"
 w(10) = "array"
 w(11) = "maybe"
 DIM choice AS INTEGER
 choice = multichoice("Inset which kind of widget?", w(), , , "ee_prompt_for_widget_kind")
 IF choice = -1 THEN RETURN ""
 RETURN w(choice)
END FUNCTION

FUNCTION ee_create_widget(BYREF st AS EEState, kind AS STRING) AS Reload.NodePtr
 DIM widget AS Reload.NodePtr
 widget = Reload.CreateNode(st.doc, "widget")
 Reload.SetContent(widget, kind)
 '--If any widget kind had any strictly mandatory sub-nodes, we could add them here...
 '  ...but I am not sure we will actually have any of those.
 SELECT CASE kind
  CASE "int":
  CASE "string":
  CASE "label":
  CASE "bit":
  CASE "submenu":
  CASE "picture":
  CASE "item":
  CASE "attack":
  CASE "tag":
  CASE "tagcheck":
  CASE "array":
  CASE "maybe":
  CASE ELSE
   debug "Oops! Created a widget of kind """ & kind & """, but we have no idea what that is!"
 END SELECT
 RETURN widget
END FUNCTION

FUNCTION ee_container_check(BYVAL cont AS Reload.NodePtr, BYVAL widget AS Reload.NodePtr) AS INTEGER
 IF cont = 0 THEN RETURN NO
 IF widget = 0 THEN RETURN NO
 SELECT CASE Reload.GetString(cont)
  CASE "submenu": RETURN YES
  CASE "array": RETURN YES
  CASE "maybe": RETURN YES
 END SELECT
 RETURN NO
END FUNCTION

FUNCTION ee_widget_has_caption(BYVAL widget AS Reload.NodePtr) AS INTEGER
 'True for widgets that use a caption node.
 IF widget = 0 THEN RETURN NO
 SELECT CASE Reload.GetString(widget)
  CASE "array": RETURN NO
  CASE "maybe": RETURN NO
 END SELECT
 RETURN YES
END FUNCTION

FUNCTION ee_widget_has_data(BYVAL widget AS Reload.NodePtr) AS INTEGER
 'True for widgets that use a data node
 IF widget = 0 THEN RETURN NO
 SELECT CASE Reload.GetString(widget)
  CASE "label": RETURN NO
  CASE "submenu": RETURN NO
  CASE "maybe": RETURN NO
 END SELECT
 RETURN YES
END FUNCTION

FUNCTION ee_edit_widget_details(BYVAL widget AS Reload.NodePtr) AS INTEGER
 IF widget = 0 THEN RETURN NO
 DIM kind AS STRING
 kind = Reload.GetString(widget)
 SELECT CASE kind
  CASE "int":    debug kind & " editor"
  CASE "string": debug kind & " editor"
  CASE "label":  debug kind & " editor"
  CASE "bit":    debug kind & " editor"
  CASE "picture":  debug kind & " editor"
  CASE "item":     debug kind & " editor"
  CASE "attack":   debug kind & " editor"
  CASE "tagcheck": debug kind & " editor"
  CASE "tag":      debug kind & " editor"
  CASE "array": debug kind & " editor"
  CASE "maybe": debug kind & " editor"
 END SELECT
 
 IF widget_editor(widget) THEN RETURN YES
 
 RETURN NO
END FUNCTION

'-----------------------------------------------------------------------

FUNCTION widget_editor(BYVAL widget AS Reload.NodePtr) AS INTEGER

 DIM st AS WEState
 
 st.changed = NO

 st.state.pt = 0
 st.state.need_update = YES
 st.state.active = YES

 ClearMenuData st.menu
 WITH st.menu
  .anchor.x = 0
  .anchor.y = 0
  .offset.x = 0
  .offset.y = 0
  .bordersize = -4
  .align = -1
  .maxrows = 18
 END WITH
 
 setkeys
 DO
  setwait 55
  setkeys

  IF st.state.need_update THEN
   DeleteMenuItems st.menu
   widget_editor_refresh st, widget
   init_menu_state st.state, st.menu
   st.state.need_update = NO
  END IF
  
  IF keyval(scESC) > 1 THEN
   EXIT DO 
  END IF
  IF keyval(scF1) > 1 THEN show_help("widget_editor")

  st.shift = (keyval(scLeftShift) > 0 OR keyval(scRightShift) > 0)
  
  IF st.state.pt >= 0 AND st.state.pt <= st.menu.numitems - 1 THEN
   'ee_edit_menu_item st, st.menu.items[st.state.pt]
  END IF
  
  IF NOT st.shift THEN
   usemenu st.state
  END IF

  clearpage dpage
  draw_menu st.menu, st.state, dpage
  edgeprint "F1=Help", 0, 190, uilook(uiText), dpage

  SWAP vpage, dpage
  setvispage vpage
  dowait
 LOOP

 DeleteMenuItems st.menu

 RETURN NO 
END FUNCTION

SUB widget_editor_refresh(BYREF st AS WEState, BYVAL widget AS Reload.NodePtr)
 DIM index AS INTEGER
 index = append_menu_item(st.menu, "Done Editing this Widget...")
 index = append_menu_item(st.menu, "Caption:" & Reload.GetChildNodeStr(widget, "caption"))
 index = append_menu_item(st.menu, "Data Node:" & Reload.GetChildNodeStr(widget, "data"))
END SUB
