cmake_minimum_required(VERSION 3.10)
project(indi-aapa C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add current dir to module path to find FindINDI.cmake
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_SOURCE_DIR}")

find_package(INDI REQUIRED)

if(INDI_FOUND)
    message(STATUS "Found INDI: ${INDI_INCLUDE_DIR}")
    include_directories(${INDI_INCLUDE_DIR})
else()
    message(FATAL_ERROR "INDI library not found!")
endif()

set(AAPA_SRCS
    src/aapa_driver.cpp
)

add_executable(indi_aapa_polaralignment ${AAPA_SRCS})

# INDI drivers often need nova and curl
target_link_libraries(indi_aapa_polaralignment ${INDI_LIBRARIES} m)

install(TARGETS indi_aapa_polaralignment RUNTIME DESTINATION bin)
install(FILES src/aapa_polaralignment.xml DESTINATION share/indi RENAME indi_aapa_polaralignment.xml)
