#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "openjp2" for configuration "Release"
set_property(TARGET openjp2 APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(openjp2 PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LINK_INTERFACE_LIBRARIES_RELEASE "m"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libopenjp2.a"
  )

list(APPEND _cmake_import_check_targets openjp2 )
list(APPEND _cmake_import_check_files_for_openjp2 "${_IMPORT_PREFIX}/lib/libopenjp2.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
