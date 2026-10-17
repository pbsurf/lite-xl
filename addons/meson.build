# Native parts of our add-ons, built into the build dir (not installed).
# scripts/run.sh links each into the user dir's installed plugin, where
# package.cpath finds it as <module>.<arch_tuple>.so.
if host_machine.system() != 'windows'
    shared_module('libterminal', 'plugins' / 'terminal' / 'libterminal.c',
        name_prefix : '',
        name_suffix : arch_tuple + '.so',
        include_directories : include_directories('..' / 'resources' / 'include'),
        dependencies : cc.find_library('util'),
    )
endif

hunspell_dep = dependency('hunspell', required : false)
if hunspell_dep.found()
    shared_module('hunspell', 'plugins' / 'spellcheck' / 'hunspell.c',
        name_prefix : '',
        name_suffix : arch_tuple + '.so',
        include_directories : include_directories('..' / 'resources' / 'include'),
        dependencies : hunspell_dep,
    )
endif
