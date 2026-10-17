# lpm, the plugin manager scripts/lpm runs, built into the build dir (not
# installed). It loads src/lpm.lua from this source directory when it starts,
# so edits to it need no rebuild. Self-upgrade is disabled.
lpm_deps = [
    lua_dep,
    dependency('zlib'),
    dependency('liblzma'),
    dependency('libgit2'),
    dependency('libzip'),
    dependency('mbedtls'),
    dependency('mbedx509'),
    dependency('mbedcrypto'),
    dependency('threads'),
]

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
