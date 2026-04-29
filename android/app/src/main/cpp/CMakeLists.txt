cmake_minimum_required(VERSION 3.22.1)

project("walkie_talkie_audio")

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add Oboe library
set(OBOE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/oboe)
add_subdirectory(${OBOE_DIR} ./oboe)

# Add Opus library
set(OPUS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/opus)
add_subdirectory(${OPUS_DIR} ./opus)

# Include directories
include_directories(${OBOE_DIR}/include)
include_directories(${OPUS_DIR}/include)

# Create the audio engine library
add_library(walkie_talkie_audio SHARED
    audio_engine.cpp
    audio_mixer.cpp
    opus_codec.cpp
    peer_audio_manager.cpp
)

# Link libraries
target_link_libraries(walkie_talkie_audio
    oboe
    opus
    log
    android
)
