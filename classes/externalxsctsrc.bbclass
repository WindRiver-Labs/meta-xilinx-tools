# Copyright (C) 2017 Xilinx
# Based on externalsrc.bbclass, original copyrights follow:
# Copyright (C) 2012 Linux Foundation
# Some code and influence taken from srctree.bbclass:
# Copyright (C) 2009 Chris Larson <clarson@kergoth.com>
# Released under the MIT license (see COPYING.MIT for the terms)

SRCTREECOVEREDTASKS ?= "do_patch do_unpack do_fetch"

python () {
    externalsrc = d.getVar('EXTERNALXSCTSRC', True)
    if externalsrc:
        d.setVar('S', externalsrc)
        externalsrcbuild = d.getVar('EXTERNALXSCTSRC_BUILD', True)
        if externalsrcbuild:
            d.setVar('B', externalsrcbuild)
        else:
            d.setVar('B', '${WORKDIR}/${BPN}-${PV}/')

        if d.getVar('S', True) == d.getVar('B', True):
            bb.error("Cannot set build directory to be same as source directory")
            return None

        local_srcuri = []
        fetch = bb.fetch2.Fetch((d.getVar('SRC_URI', True) or '').split(), d)
        for url in fetch.urls:
            url_data = fetch.ud[url]
            if (url_data.type == 'file'):
                    local_srcuri.append(url)

        d.setVar('SRC_URI', ' '.join(local_srcuri))

        if '{SRCPV}' in d.getVar('PV', False):
            # Dummy value because the default function can't be called with blank SRC_URI
            d.setVar('SRCPV', '999')

        tasks = filter(lambda k: d.getVarFlag(k, "task", True), d.keys())

        for task in tasks:
            if task.endswith("_setscene"):
                # sstate is never going to work for external source trees, disable it
                bb.build.deltask(task, d)
            else:
                # Since configure will likely touch ${S}, ensure only we lock so one task has access at a time
                d.appendVarFlag(task, "lockfiles", " ${TMPDIR}/singletask.lock")

            # We do not want our source to be wiped out, ever (kernel.bbclass does this for do_clean)
            cleandirs = (d.getVarFlag(task, 'cleandirs', False) or '').split()
            setvalue = False
            for cleandir in cleandirs[:]:
                if d.expand(cleandir) == externalsrc:
                    cleandirs.remove(cleandir)
                    setvalue = True
            if setvalue:
                d.setVarFlag(task, 'cleandirs', ' '.join(cleandirs))

        fetch_tasks = ['do_fetch', 'do_unpack']
        # If we deltask do_patch, there's no dependency to ensure do_unpack gets run, so add one
        # Note that we cannot use d.appendVarFlag() here because deps is expected to be a list object, not a string
        d.setVarFlag('do_configure', 'deps', (d.getVarFlag('do_configure', 'deps', False) or []) + ['do_unpack'])

        for task in d.getVar("SRCTREECOVEREDTASKS", True).split():
            if local_srcuri and task in fetch_tasks:
                continue
            bb.build.deltask(task, d)

        d.prependVarFlag('do_compile', 'prefuncs', "xsct_externalsrc_compile_prefunc")

        d.setVarFlag('do_compile', 'file-checksums', '${@xsct_srctree_hash_files(d)} ${@xsct_buildtree_hash_files(d)}')

        # We don't want the workdir to go away
        d.appendVar('RM_WORK_EXCLUDE', ' ' + d.getVar('PN', True))
}

COMPILE_TRIGGER_FILES = " \
    ${XSCTH_WS}/${XSCTH_PROJ}/src \
    ${XSCTH_WS}/${XSCTH_PROJ}_bsp/${XSCTH_PROC} \
    ${XSCTH_WS}/${XSCTH_PROJ}_hwproj \
    "

do_configure[file-checksum] += "${XSCTH_HDF}:True"

python xsct_externalsrc_compile_prefunc() {
    # Make it obvious that this is happening, since forgetting about it could lead to much confusion
    bb.plain('NOTE: %s: compiling from external source tree %s' % (d.getVar('PN', True), d.getVar('EXTERNALXSCTSRC', True)))
}

def xsct_srctree_hash_files(d):
    import shutil
    import subprocess
    import tempfile

    s_dir = d.getVar('EXTERNALXSCTSRC', True)
    git_dir = os.path.join(s_dir, '.git')
    oe_hash_file = os.path.join(git_dir, 'oe-devtool-tree-sha1')

    ret = " "
    if os.path.exists(git_dir):
        with tempfile.NamedTemporaryFile(dir=git_dir, prefix='oe-devtool-index') as tmp_index:
            # Clone index
            shutil.copy2(os.path.join(git_dir, 'index'), tmp_index.name)
            # Update our custom index
            env = os.environ.copy()
            env['GIT_INDEX_FILE'] = tmp_index.name
            subprocess.check_output(['git', 'add', '.'], cwd=s_dir, env=env)
            sha1 = subprocess.check_output(['git', 'write-tree'], cwd=s_dir, env=env).decode("utf-8")
        with open(oe_hash_file, 'w') as fobj:
            fobj.write(sha1)
        ret = oe_hash_file + ':True'
    else:
        ret = d.getVar('EXTERNALXSCTSRC', True) + '/*:True'
    return ret

def xsct_buildtree_hash_files(d):
    """
    Get the list of files that should trigger do_compile to re-execute,
    """
    in_files = (d.getVar('COMPILE_TRIGGER_FILES', True) or '').split()
    out_items = []
    for entry in in_files:
        if os.path.isdir(entry):
            out_items.append('%s/*:%s' % (entry, os.path.exists(entry)))
        else:
            out_items.append('%s:%s' % (entry, os.path.exists(entry)))
    return ' '.join(out_items)