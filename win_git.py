#!/usr/bin/python
# -*- coding: utf-8 -*-

# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

# Anatoliy Ivashina <tivrobo@gmail.com>
# Pablo Estigarribia <pablodav@gmail.com>
# Michael Hay <project.hay@gmail.com>


DOCUMENTATION = r"""
---
module: win_git
version_added: "2.0"
short_description: Deploy software \(or files\) from git checkouts
description:
    - Deploy software \(or files\) from git checkouts
    - SSH only
notes:
    - git for Windows need to be installed
    - SSH only
options:
  repo:
    description:
      - address of the repository
    required: true
    aliases: [ name ]
  dest:
    description:
      - destination folder
    required: true
  replace_dest:
    description:
      - Replace destination folder if exists \(recursive\).
    required: false
    default: false
  accept_hostkey:
    description:
      - Add hostkey to known_hosts \(before connecting to git\)?
    required: false
    default: false
  update:
    description:
      - Update the repository\?
    required: false
    default: false
  clone:
    description:
      - Clone the repository\?
    required: false
    default: false
  recursive:
    description:
      - If C(no), repository will be cloned without the C(--recursive) option, skipping sub-modules.
    type: bool
    default: 'yes'
  branch:
    description:
      - The branch to pull from.
    required: false
    default: master
author:
- Anatoliy Ivashina
- Pablo Estigarribia
- Michael Hay
"""

EXAMPLES = r"""
  # git clone cool-thing.
  win_git:
    repo: "git@github.com:tivrobo/Ansible-win_git.git"
    dest: "{{ ansible_env.TEMP }}\\Ansible-win_git"
    branch: master
    update: no
    replace_dest: no
    accept_hostkey: yes
"""
