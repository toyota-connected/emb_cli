cmake_minimum_required(VERSION 3.16)
project(cmake_lib C)

add_library(cmake_lib SHARED lib.c)
set_target_properties(cmake_lib PROPERTIES PREFIX "lib")
