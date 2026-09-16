cmake_minimum_required(VERSION 3.22.1)
project(tile_decoder C)

add_library(tile_decoder SHARED tile_decoder.c)

# jnigraphics provides AImageDecoder. Nothing else is linked, and nothing is
# vendored — the decoder is part of Android.
find_library(jnigraphics-lib jnigraphics)
target_link_libraries(tile_decoder ${jnigraphics-lib})
