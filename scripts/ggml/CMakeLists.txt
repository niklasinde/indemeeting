# llama.cpp brings ggml; whisper.cpp sees the ggml target and builds against it, so the app links one copy of ggml.
cmake_minimum_required(VERSION 3.14)
project(worktime-ggml C CXX)
add_subdirectory(${LLAMA_SOURCE} llama)
add_subdirectory(${WHISPER_SOURCE} whisper)
