cmake_minimum_required(VERSION 3.16)
project(indi-oapa CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}")

find_package(INDI 2.2 COMPONENTS driver REQUIRED)

# The PAC interface that Ekos drives appeared in INDI 2.2.0.
if(NOT EXISTS "${INDI_INCLUDE_DIR}/indipacinterface.h")
    message(FATAL_ERROR "INDI ${INDI_VERSION} has no PAC interface (indipacinterface.h). INDI >= 2.2.0 is required.")
endif()

include_directories(${INDI_INCLUDE_DIR})

add_executable(indi_oapa src/oapa.cpp)
target_link_libraries(indi_oapa ${INDI_LIBRARIES})

install(TARGETS indi_oapa RUNTIME DESTINATION bin)
install(FILES src/indi_oapa.xml DESTINATION share/indi)
