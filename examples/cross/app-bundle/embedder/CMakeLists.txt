cmake_minimum_required(VERSION 3.16)
project(hello-embedder C)

add_executable(hello-embedder main.c)
target_link_libraries(hello-embedder PRIVATE ${CMAKE_DL_LIBS})
install(TARGETS hello-embedder RUNTIME DESTINATION bin)
