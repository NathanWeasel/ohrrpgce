#!/usr/bin/env python
import os
import sys
import time
import cPickle as pickle
import numpy as np
import re
from nohrio.ohrrpgce import *
from nohrio.dtypes import dt
from nohrio.wrappers import OhrData
from nohrio.scripts import *
from rpgbatch import RPGIterator, RPGInfo

if len(sys.argv) < 2:
    print "Usage:"
    print " scanscripts.py [--resume scriptdata.bin | plotscr.hs] [src:identifier] locations ..."
    print "Optionally pass plotscr.hs (plotscr.hsd compiled) as the first argument to identify the standard scripts."
    print "scriptdata.bin is created in the current directory, which can be passed using --resume"
    print "to combine runs of the utility."
    print "Specify .rpg files, .rpgdir directories, .zip files, or directories containing any of these as arguments."
    sys.exit()
things = sys.argv[1:]

table_size = 2000
cmdcounts = np.zeros(shape = (0, table_size), dtype = np.int32)
cmdcounts_in_plotscrhsd = np.zeros((table_size), np.int32)

commands_info = {}
scripthashes = {}
rpgidx = np.zeros(shape = 0, dtype = RPGInfo)

standardscrs = {'names': [], 'versions':[], 'games':[]}

scriptbytes = 0
scriptuniquebytes = 0
scriptnum = 0
scriptuniquenum = 0

# All uses of the following script commands will be logged and printed
# You can also add standard script names to this, eg. 'minutesofplay':''
# noop, stringfromtextbox, initmouse, readgeneral, writegeneral, readgmap, writegmap, readenemydata, writeenemydata
cmd_logging = {0:'', 240:'', 159:'', 147:'', 148:'', 178:'', 179:'', 230:'', 231:''}

strange_names = []


if things[0] == '--resume':
    with open(things[1], 'rb') as f:
        state = pickle.load(f)
        locals().update(state)
    things = things[2:]
    rpgs.set_input(things)
    print
    print "Resuming from previous run:"
    print rpgs.messages
    print "New run:"


elif things[0].endswith('plotscr.hs'):
    scriptset = HSScripts(things[0])
    standardscrs['names'] = scriptset.scriptnames.values()
    commands_info = scriptset.commands_info
    del scriptset
    print "Read", len(standardscrs['names']), "standard scripts from", things[0]
    things.pop(0)
    # A few special cases for scripts which were removed from plotscr.hsd
    # (all of these were in fact replaced with builtin commands)
    for n in ('setstring', 'appendstring', 'suspendmapmusic', 'resumemapmusic', 'setenemyrewards', 'getenemyrewards'):
        if n not in standardscrs['names']:
            standardscrs['names'].append(n)
    standardscrs['versions'] = [0 for x in standardscrs['names']]
    standardscrs['games'] = [[] for x in standardscrs['names']]

    # We'll store usage counts for both commands and standard scripts in cmdcount.
    # The scripts start at 2000.
    table_size = 2000 + len(standardscrs['names'])

    cmdcounts = np.zeros(shape = (0, table_size), dtype = np.int32)
    cmdcounts_in_plotscrhsd = np.zeros((table_size), np.int32)

    rpgs = RPGIterator(things)


def iter_script_tree2(root):
    yield root
    for arg in root.args():
        # Wow! Passing each item back up the call chain has got to be inefficient!
        for ret in iter_script_tree(arg):
            yield ret

# This is about 30% faster than iter_script_tree2... disappointing
def iter_script_tree(root):
    "Iterate over the descendents of a script node"
    node = ScriptNode(root.scriptset(), root.script, root.offset)
    yield node
    if root.argnum == 0:
        return
    lst = [root.offset + 3, root.argnum]
    data = root.scrdata()
    while len(lst):
        node.offset = data[lst[-2]]
        yield node
        if lst[-1] == 1:
            lst = lst[:-2]
        else:
            lst[-2] += 1
            lst[-1] -= 1
        argnum = node.argnum
        if argnum:
            lst.append(node.offset + 3)
            lst.append(argnum)

# Map from name to index in standardscrs
standardindex = {}
for i, name in enumerate(standardscrs['names']):
    standardindex[name] = i

def commandname(id):
    if id in commands_info:
        return commands_info[id]['name']
    return "cmd%d" % id


for rpg, gameinfo, zipinfo in rpgs:
    gameinfo.has_source = False
    gameinfo.scripts_backup = False
    if zipinfo:
        gameinfo.has_source = (len(zipinfo.scripts) > 0)
    gameinfo.loadname(rpg)
    rpgidx = np.append(rpgidx, gameinfo)

    cmdusage = np.zeros((1, table_size), np.int32)

    hspfile = rpg.lump_path('.hsp')
    gameinfo.has_scripts = os.path.isfile(hspfile)
    if gameinfo.has_scripts:
        scriptset = HSScripts(hspfile)
        gameinfo.scripts_backup = scriptset.source

        # Use whichever commands.bin lump has the most in it
        if len(scriptset.commands_info) > len(commands_info):
            commands_info = scriptset.commands_info

        # Map script IDs to standardscrs indices
        id_to_standardindex = {}
        for id, name in scriptset.scriptnames.iteritems():
            idx = standardindex.get(name)
            if idx:
                id_to_standardindex[id] = idx

        for name in scriptset.scriptnames.itervalues():
            if re.search('(^[0-9-]|[^a-z0-9_-])', name):
                strange_names.append((name, gameinfo.id))

        for id in scriptset.scriptnames.iterkeys():
            script = scriptset.script(id)
            if not script:
                continue
            scriptnum += 1
            #script = copy(script)
            #script.drop_data()
            script.game = gameinfo.name  # RPG file and long name
            script.gamename = gameinfo.longname
            scriptbytes += script.lump_size

            # The first Script in each list of Scripts in scripthashes has a vector of
            # command usage counts for that script (hacky)
            md5 = script.invariate_md5()
            if md5 in scripthashes:
                # Only need one copy of the script data
                script.drop_data()
                scripthashes[md5].append(script)
                # Commands in standard scripts are only counted once per unique copy of the script.
                # Commands in other scripts are counted for each game they appear in
                if script.name not in standardindex:
                    cmdusage[0] += scripthashes[md5][0].cmdusage
            else:
                script.cmdusage = np.zeros((table_size), np.int32)
                scriptuniquenum += 1
                scripthashes[md5] = [script]
                scriptuniquebytes += script.lump_size

                for node in iter_script_tree(script.root()):
                    kind = node.kind
                    if kind == kCmd:
                        script.cmdusage[node.id] += 1
                        # Ignore occurrences in standard scripst
                        if node.id in cmd_logging and id not in id_to_standardindex:
                            cmd_logging[node.id] += "Found in " + script.name + " in " + gameinfo.name + ":\n" + str(node) + '\n'
                    elif kind == kScript:
                        idx = id_to_standardindex.get(node.id)
                        # Ignore occurrences in standard scripts
                        if idx and id not in id_to_standardindex:
                            script.cmdusage[2000 + idx] += 1
                            if standardscrs['names'][idx] in cmd_logging:
                                cmd_logging[standardscrs['names'][idx]] += "Found in " + script.name + " in " + gameinfo.name + ":\n" + str(node) + '\n'
                if script.name in standardindex:
                    cmdcounts_in_plotscrhsd += script.cmdusage
                else:
                    cmdusage[0] += script.cmdusage
        scriptset.close()
        del scriptset

    cmdcounts = np.append(cmdcounts, cmdusage, axis = 0)

print
rpgs.print_summary()
#del rpgs
print "Scanned %d unique scripts totalling %.2f MB (%.2f MB nonunique)" % (scriptuniquenum, scriptuniquebytes / 2.**20, scriptbytes / 2.**20)
print

almost_dup = 0
for md5, scripts in scripthashes.iteritems():
    if len(scripts) > 1 and scripts[0].name not in standardindex:
        games = []
        duptext = ''
        for script in scripts:
            if script.game not in games:
                games.append(script.game)
                duptext += "\n   " + script.name + " in " + script.game
        if len(games) > 1:
            if len(set(script.gamename for script in scripts)) == 1:
                almost_dup += 1
            else:
                print "Script duplicated", len(games), "times:", duptext
print
print "Ignored %d duplicated scripts which seem to be from different versions of the same game" % almost_dup

if len(strange_names):
    print "Saw script names containing unusual characters:"
    for name, game in strange_names:
        print "\"" + name + "\" in " + game

print

for cmdid, log in cmd_logging.iteritems():
    if isinstance(cmdid, int):
        name = commandname(cmdid)
    print "--- All uses of %s (aside from standard scripts) ---" % name
    print log

rpgidx = rpgidx.view(OhrData)

# Delete weakrefs from scripts so that they are pickleable
for scripts in scripthashes.itervalues():
    for script in scripts:
        if hasattr(script, 'scriptset'):
            if script.scriptset() != None:
                print "WARNING: undeleted HSScripts object"
            del script.scriptset

state = {}
for var in 'rpgidx', 'rpgs', 'cmdcounts', 'cmdcounts_in_plotscrhsd', 'standardscrs', 'scripthashes', 'commands_info', 'table_size', 'cmd_logging', 'scriptbytes', 'scriptuniquebytes', 'scriptnum', 'scriptuniquenum':
    state[var] = locals()[var]
with open('scriptdata.bin', 'wb') as f:
    pickle.dump(state, f, protocol = 2)

print

tally = np.zeros((len(rpgidx), 2, 2, 3), dtype = np.int)
for i, r in enumerate(rpgidx):
    backup_type = 0
    if r.scripts_backup == 'source.txt':
        backup_type = 1
    elif r.scripts_backup == 'source.lumped':
        backup_type = 2
    tally[i, r.has_scripts, r.has_source, backup_type] = 1

tally = tally.sum(axis=0)

print "%d/%d games had imported scripts:" % (tally[1].sum(), len(rpgidx))
tally = tally[1]
print "                no backup   |   source.txt   |   source.lumped"
print "no orig. src       %3d             %3d                %3d" % tuple(tally[0])
print "with orig. src     %3d             %3d                %3d" % tuple(tally[1])

total = tally.sum()
print
print "in sum %d/%d games had script source available" % (total - tally[0][0].sum(), total)

print 


# Print out usage counts for commands AND plotscr.hsd scripts

for scripts in scripthashes.itervalues():
    idx = standardindex.get(scripts[0].name)
    if idx:
        standardscrs['versions'][idx] += 1

cmdsums = cmdcounts.sum(axis=0)
cmdgamecounts = (cmdcounts > 0).sum(axis=0)
for i in xrange(len(cmdsums)):
    if cmdsums[i] or cmdcounts_in_plotscrhsd[i] or (i in commands_info) or i >= 2000:
        if i >= 2000:
            header = standardscrs['names'][i - 2000] + " (%d versions)" % standardscrs['versions'][i - 2000]
        else:
            header =  "%-3s%s" % (str(i) + ':', commandname(i))
        mark = ''
        header += ' ' * max(1, 41 - len(header) - len(str(cmdsums[i])))
        print "%s%d uses in %3d games + %2d in plotscr.hsd" % (header, cmdsums[i], cmdgamecounts[i], cmdcounts_in_plotscrhsd[i])
