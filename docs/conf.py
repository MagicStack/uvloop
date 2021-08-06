#!/usr/bin/env python3

import alabaster
import os
import sys

sys.path.insert(0, os.path.abspath('..'))

version_file = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                            'uvloop', '_version.py')

with open(version_file, 'r') as f:
    for line in f:
        if line.startswith('__version__ ='):
            _, _, version = line.partition('=')
            version = version.strip(" \n'\"")
            break
    else:
        raise RuntimeError(
            'unable to read the version from uvloop/_version.py')


# -- General configuration ------------------------------------------------

extensions = [
    'sphinx.ext.autodoc',
    'alabaster',
]
templates_path = ['_templates']
source_suffix = '.rst'
master_doc = 'index'
project = 'uvloop'
copyright = '2016-present, MagicStack, Inc'
author = 'Yury Selivanov'
release = version
language = None
exclude_patterns = ['_build']
pygments_style = 'sphinx'
todo_include_todos = False


# -- Options for HTML output ----------------------------------------------

html_theme = 'alabaster'
html_theme_options = {
    'description': 'uvloop is an ultra fast implementation of the '
                   'asyncio event loop on top of libuv.',
    'show_powered_by': False,
}
html_theme_path = [alabaster.get_path()]
html_title = 'uvloop Documentation'
html_short_title = 'uvloop'
html_static_path = []
html_sidebars = {
    '**': [
        'about.html',
        'navigation.html',
    ]
}
html_show_sourcelink = False
html_show_sphinx = False
html_show_copyright = True
htmlhelp_basename = 'uvloopdoc'


# -- Options for LaTeX output ---------------------------------------------

latex_elements = {}

latex_documents = [
    (master_doc, 'uvloop.tex', 'uvloop Documentation',
     'Yury Selivanov', 'manual'),
]


# -- Options for manual page output ---------------------------------------

man_pages = [
    (master_doc, 'uvloop', 'uvloop Documentation',
     [author], 1)
]


# -- Options for Texinfo output -------------------------------------------

texinfo_documents = [
    (master_doc, 'uvloop', 'uvloop Documentation',
     author, 'uvloop', 'One line description of project.',
     'Miscellaneous'),
]
