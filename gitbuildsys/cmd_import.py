#!/usr/bin/python -tt
# vim: ai ts=4 sts=4 et sw=4
#
# Copyright (c) 2012 Intel, Inc.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation; version 2 of the License
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc., 59
# Temple Place - Suite 330, Boston, MA 02111-1307, USA.

"""Implementation of subcmd: import
"""
import os

from gitbuildsys import msger
from gitbuildsys.cmd_export import get_packaging_dir
from gitbuildsys.utils import Temp
from gitbuildsys.conf import configmgr

from gbp.scripts.import_srpm import main as gbp_import_srpm
from gbp.scripts.import_orig_rpm import main as gbp_import_orig

def main(args):
    """gbs import entry point."""

    if args.author_name:
        os.environ["GIT_AUTHOR_NAME"] = args.author_name
    if args.author_email:
        os.environ["GIT_AUTHOR_EMAIL"] = args.author_email

    path = args.path

    tmp = Temp(prefix='gbp_',
               dirn=configmgr.get('tmpdir', 'general'),
               directory=True)

    params = ["argv[0] placeholder",
              "--color-scheme=magenta:green:yellow:red",
              "--packaging-dir=%s" % get_packaging_dir(args),
              "--upstream-branch=%s" % args.upstream_branch, path,
              "--tmp-dir=%s" % tmp.path,
              ]
    if not args.no_pristine_tar and os.path.exists("/usr/bin/pristine-tar"):
        params.append("--pristine-tar")

    if path.endswith('.src.rpm') or path.endswith('.spec'):
        ret = gbp_import_srpm(params)
        if ret == 2:
            msger.warning("Importing of patches into packaging branch failed! "
                          "Please import manually (apply and commit to git, "
                          "remove files from packaging dir and spec) in order "
                          "to enable automatic patch generation.")
        elif ret:
            msger.error("Failed to import %s" % path)
    else:
        if args.merge:
            params.append('--merge')
        else:
            params.append('--no-merge')
        if gbp_import_orig(params):
            msger.error('Failed to import %s' % path)

    msger.info('done.')
