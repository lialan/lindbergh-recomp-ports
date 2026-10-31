cmake_minimum_required(VERSION 3.20)
project(lindbergh_recomp_ports VERSION 0.1.0 LANGUAGES C)
if(APPLE)
    enable_language(OBJC)       # the runtime's macOS menu bar
endif()

# Sega Lindbergh games, statically recompiled: one folder per game under
# games/ (ghostsquadevolution, hotd4), all on the lindberghrecomp runtime.
#
# A game's target only exists once you have lifted its ELF into
# games/<game>/generated, because the runtime needs two headers generated
# from it. Without any this still configures and builds the toolkit's own
# self-check, so the repo is testable out of the box.
#
#   ./scripts/build-macos.sh <game> /path/to/the/game       (macOS)
#   py -3.11 -m tools recomp <elf> ..\games\<game>\generated  (Windows, see the README)
#   cmake -S . -B build -A Win32
#   cmake --build build --config Release
#
# LINDBERGH_GAMES=<game;...> builds only those (the Quest build makes one
# game per build tree: each is the app's libmain.so).

set(LINDBERGH_GAMES "" CACHE STRING "games to build (empty: every one with lifted code)")

add_subdirectory(lindberghrecomp)

function(lindbergh_game id)
    set(src "${CMAKE_CURRENT_SOURCE_DIR}/games/${id}/src")
    set(gen "${CMAKE_CURRENT_SOURCE_DIR}/games/${id}/generated")
    file(GLOB lifted "${gen}/recomp_funcs_*.c")
    if(NOT lifted OR NOT EXISTS "${gen}/recomp_imports.h")
        message(STATUS "${id}: no lifted code in ${gen} yet, not built. See the README.")
        return()
    endif()
    if(ANDROID)
        # Meta Quest: SDL's Java side loads libmain.so and calls SDL_main
        # (android_main.c), which runs host.c's main.
        add_library(${id} SHARED "${src}/host.c" "${src}/android_main.c" ${lifted})
        set_target_properties(${id} PROPERTIES OUTPUT_NAME main)
        set_source_files_properties("${src}/host.c" PROPERTIES COMPILE_DEFINITIONS main=game_main)
    else()
        add_executable(${id} "${src}/host.c" ${lifted})
    endif()
    if(NOT WIN32 OR CMAKE_SIZEOF_VOID_P EQUAL 8)
        # Typed GL thunks for a 64-bit host, generated from the host's GL
        # headers (lindberghrecomp/tools/gen_gl_thunks.py): on the Quest from
        # gl4es' when the game has its own set for them
        if(WIN32)
            target_sources(${id} PRIVATE "${gen}/recomp_gl_thunks_windows.c")
        elseif(ANDROID AND EXISTS "${gen}/recomp_gl_thunks_android.c")
            target_sources(${id} PRIVATE "${gen}/recomp_gl_thunks_android.c")
        else()
            target_sources(${id} PRIVATE "${gen}/recomp_gl_thunks.c")
        endif()
        # libraries the game dlopens, lifted by lindberghrecomp/tools/recomp/solib.py
        file(GLOB solib "${gen}/recomp_solib_*.c")
        target_sources(${id} PRIVATE ${solib})
    endif()
    lindbergh_runtime(${id} "${gen}")
    message(STATUS "${id}: building against lifted code in ${gen}")
endfunction()

file(GLOB game_dirs LIST_DIRECTORIES true "${CMAKE_CURRENT_SOURCE_DIR}/games/*")
foreach(dir ${game_dirs})
    if(IS_DIRECTORY "${dir}" AND EXISTS "${dir}/src/host.c")
        get_filename_component(id "${dir}" NAME)
        if(NOT LINDBERGH_GAMES OR id IN_LIST LINDBERGH_GAMES)
            lindbergh_game(${id})
        endif()
    endif()
endforeach()
