# SPDX-License-Identifier: GPL-2.0-or-later
# Configure with -DUML_APPLE_PLATFORM=macos|ios|ios-simulator.

set(UML_APPLE_PLATFORM "macos" CACHE STRING "Apple target platform")
set(UML_APPLE_DEPLOYMENT_TARGET "" CACHE STRING
    "Optional Apple deployment target override (>= platform floor)")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
    UML_APPLE_PLATFORM
    UML_APPLE_DEPLOYMENT_TARGET)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Apple architectures" FORCE)

# Each platform's SDK, CMake system name, and minimum deployment floor.
if(UML_APPLE_PLATFORM STREQUAL "macos")
    set(_uml_apple_platform macosx Darwin)
    set(_uml_apple_deployment_floor 15.0)
elseif(UML_APPLE_PLATFORM STREQUAL "ios")
    set(_uml_apple_platform iphoneos iOS)
    set(_uml_apple_deployment_floor 16.0)
elseif(UML_APPLE_PLATFORM STREQUAL "ios-simulator")
    set(_uml_apple_platform iphonesimulator iOS)
    set(_uml_apple_deployment_floor 16.0)
else()
    message(FATAL_ERROR "Unknown UML_APPLE_PLATFORM=${UML_APPLE_PLATFORM}")
endif()
list(POP_FRONT _uml_apple_platform _uml_apple_sdk CMAKE_SYSTEM_NAME)
execute_process(
    COMMAND xcrun --sdk ${_uml_apple_sdk} --show-sdk-path
    OUTPUT_VARIABLE _uml_apple_sdk_path
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
set(CMAKE_OSX_SYSROOT "${_uml_apple_sdk_path}" CACHE PATH "Apple SDK" FORCE)

set(_uml_requested_deployment_target "${_uml_apple_deployment_floor}")
if(NOT "${UML_APPLE_DEPLOYMENT_TARGET}" STREQUAL "")
    set(_uml_requested_deployment_target "${UML_APPLE_DEPLOYMENT_TARGET}")
endif()
if(NOT _uml_requested_deployment_target MATCHES "^[0-9]+(\\.[0-9]+)+$")
    message(FATAL_ERROR
        "UML_APPLE_DEPLOYMENT_TARGET=${_uml_requested_deployment_target} "
        "must be a numeric Apple OS version (for example "
        "${_uml_apple_deployment_floor}).")
endif()
if(_uml_requested_deployment_target VERSION_LESS
        "${_uml_apple_deployment_floor}")
    message(FATAL_ERROR
        "UML_APPLE_DEPLOYMENT_TARGET=${_uml_requested_deployment_target} "
        "is below the ${UML_APPLE_PLATFORM} deployment floor "
        "${_uml_apple_deployment_floor}.")
endif()

# Refuse a cached or passed CMAKE_OSX_DEPLOYMENT_TARGET below the platform
# floor (or conflicting with UML_APPLE_DEPLOYMENT_TARGET). An unset or empty
# target selects the resolved target.
if(DEFINED CMAKE_OSX_DEPLOYMENT_TARGET AND
        NOT "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "")
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET MATCHES "^[0-9]+(\\.[0-9]+)+$" OR
            CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS
                "${_uml_apple_deployment_floor}")
        message(FATAL_ERROR
            "CMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET} is cached "
            "or was passed, which is below the ${UML_APPLE_PLATFORM} deployment "
            "floor ${_uml_apple_deployment_floor}. Configure with --fresh, or in "
            "a new binary directory, to drop the cached value.")
    endif()
    if(NOT "${UML_APPLE_DEPLOYMENT_TARGET}" STREQUAL "" AND
            NOT "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL
                "${_uml_requested_deployment_target}")
        message(FATAL_ERROR
            "CMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET} conflicts "
            "with UML_APPLE_DEPLOYMENT_TARGET=${_uml_requested_deployment_target} "
            "(floor ${_uml_apple_deployment_floor}). Configure with --fresh, or "
            "in a new binary directory, to drop the cached value.")
    endif()
    set(_uml_effective_deployment_target "${CMAKE_OSX_DEPLOYMENT_TARGET}")
else()
    set(_uml_effective_deployment_target "${_uml_requested_deployment_target}")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET ${_uml_effective_deployment_target}
    CACHE STRING "Deployment target" FORCE)

# The macOS arm64 default target enables the optional mnemonics used by the
# existing assembly bodies. Standalone assembly (.S) uses runtime-dispatched
# CPU feature selection up through dotprod/fcma, whereas C++ translation units
# containing inline assembly only use armv8.2-a + fp16 + crypto instructions and
# must remain safe on Apple A11 Bionic (iPhone 8 / X on iOS 16).
if(NOT UML_APPLE_PLATFORM STREQUAL "macos")
    set(UML_APPLE_CPU_ASM_COMPILE_OPTION
        "-march=armv8.2-a+fp16+dotprod+crypto+fcma")
    set(UML_APPLE_CPU_INLINE_ASM_COMPILE_OPTION
        "-march=armv8.2-a+fp16+crypto")
    add_compile_options(
        $<$<COMPILE_LANGUAGE:ASM>:${UML_APPLE_CPU_ASM_COMPILE_OPTION}>)
endif()
