# lpm, the plugin manager scripts/lpm runs, built into the build dir (not
# installed). It loads src/lpm.lua from this source directory when it starts,
# so edits to it need no rebuild. Self-upgrade is disabled. With -Dlpm=auto (the
# default) it's skipped when a dependency is missing, as on CI.
lpm_opt = get_option('lpm')
lpm_deps = [lua_dep, dependency('threads')]
foreach name : ['zlib', 'liblzma', 'libgit2', 'libzip', 'mbedtls', 'mbedx509', 'mbedcrypto']
    lpm_deps += dependency(name, required : lpm_opt)
endforeach
lpm_found = not lpm_opt.disabled()
foreach dep : lpm_deps
    lpm_found = lpm_found and dep.found()
endforeach

if lpm_found
    executable('lpm',
        'src' / 'lpm.c',
        'lib' / 'microtar' / 'src' / 'microtar.c',
        include_directories : include_directories('lib' / 'microtar' / 'src'),
        dependencies : lpm_deps,
        c_args : [
            '-DLPM_LUA_PATH="' + meson.current_source_dir() / 'src' / 'lpm.lua' + '"',
            '-DLPM_VERSION="1.4.9"',
            '-DLPM_DEFAULT_RELEASE=""',
        ],
    )
endif
