cmake_minimum_required(VERSION 3.22.1)

project("walkie_talkie_audio")

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add Oboe library
set(OBOE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/oboe)
add_subdirectory(${OBOE_DIR} ./oboe)

# Include directories
include_directories(${OBOE_DIR}/include)

# Create the audio engine library
add_library(walkie_talkie_audio SHARED
    audio_engine.cpp
    audio_mixer.cpp
)

# Link libraries
target_link_libraries(walkie_talkie_audio
    oboe
    log
    android
)
