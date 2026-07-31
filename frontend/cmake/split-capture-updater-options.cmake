# Split Capture updater cache settings and one-cycle Split OBS aliases.

set(_split_capture_aliases_initialized FALSE)
if(DEFINED CACHE{SPLIT_CAPTURE_UPDATER_ALIASES_INITIALIZED})
  set(_split_capture_aliases_initialized TRUE)
endif()

foreach(variable IN ITEMS ENABLE_CUSTOM_UPDATER UPDATE_FEED_URL UPDATE_PUBLIC_KEY)
  if(DEFINED SPLIT_CAPTURE_${variable})
    set(_split_capture_new_${variable}_supplied TRUE)
    set(_split_capture_new_${variable}_value "${SPLIT_CAPTURE_${variable}}")
  endif()
  if(DEFINED SPLIT_OBS_${variable})
    set(_split_capture_old_${variable}_value "${SPLIT_OBS_${variable}}")
    if(
      NOT _split_capture_aliases_initialized
      OR (variable STREQUAL ENABLE_CUSTOM_UPDATER AND SPLIT_OBS_${variable})
      OR (NOT variable STREQUAL ENABLE_CUSTOM_UPDATER AND NOT "${SPLIT_OBS_${variable}}" STREQUAL "")
    )
      set(_split_capture_old_${variable}_supplied TRUE)
    endif()
  endif()
  unset(SPLIT_CAPTURE_${variable})
  unset(SPLIT_CAPTURE_${variable} CACHE)
  unset(SPLIT_OBS_${variable})
  unset(SPLIT_OBS_${variable} CACHE)
endforeach()

option(SPLIT_CAPTURE_ENABLE_CUSTOM_UPDATER "Enable the Split Capture product updater" OFF)
set(SPLIT_CAPTURE_UPDATE_FEED_URL "" CACHE STRING "Signed appcast URL for Split Capture updates")
set(SPLIT_CAPTURE_UPDATE_PUBLIC_KEY "" CACHE STRING "Ed25519 public key for Split Capture updates")

option(SPLIT_OBS_ENABLE_CUSTOM_UPDATER "Deprecated alias for SPLIT_CAPTURE_ENABLE_CUSTOM_UPDATER" OFF)
set(SPLIT_OBS_UPDATE_FEED_URL "" CACHE STRING "Deprecated alias for SPLIT_CAPTURE_UPDATE_FEED_URL")
set(SPLIT_OBS_UPDATE_PUBLIC_KEY "" CACHE STRING "Deprecated alias for SPLIT_CAPTURE_UPDATE_PUBLIC_KEY")

foreach(variable IN ITEMS ENABLE_CUSTOM_UPDATER UPDATE_FEED_URL UPDATE_PUBLIC_KEY)
  if(variable STREQUAL ENABLE_CUSTOM_UPDATER)
    set(variable_type BOOL)
  else()
    set(variable_type STRING)
  endif()
  if(_split_capture_new_${variable}_supplied)
    set(
      SPLIT_CAPTURE_${variable}
      "${_split_capture_new_${variable}_value}"
      CACHE ${variable_type}
      ""
      FORCE
    )
  endif()
  if(_split_capture_old_${variable}_supplied)
    set(SPLIT_OBS_${variable} "${_split_capture_old_${variable}_value}" CACHE ${variable_type} "" FORCE)
  endif()

  if(_split_capture_old_${variable}_supplied)
    if(
      _split_capture_new_${variable}_supplied
      AND NOT "${_split_capture_new_${variable}_value}" STREQUAL "${_split_capture_old_${variable}_value}"
    )
      message(FATAL_ERROR "Conflicting SPLIT_CAPTURE_${variable} and deprecated SPLIT_OBS_${variable} values")
    elseif(NOT _split_capture_new_${variable}_supplied)
      if(variable STREQUAL ENABLE_CUSTOM_UPDATER)
        set(SPLIT_CAPTURE_${variable} "${_split_capture_old_${variable}_value}" CACHE BOOL "" FORCE)
      else()
        set(SPLIT_CAPTURE_${variable} "${_split_capture_old_${variable}_value}" CACHE STRING "" FORCE)
      endif()
      message(DEPRECATION "SPLIT_OBS_${variable} is deprecated; use SPLIT_CAPTURE_${variable}")
    endif()
  endif()
endforeach()

mark_as_advanced(
  SPLIT_CAPTURE_UPDATE_FEED_URL
  SPLIT_CAPTURE_UPDATE_PUBLIC_KEY
  SPLIT_OBS_ENABLE_CUSTOM_UPDATER
  SPLIT_OBS_UPDATE_FEED_URL
  SPLIT_OBS_UPDATE_PUBLIC_KEY
)

set(SPLIT_CAPTURE_UPDATER_ALIASES_INITIALIZED TRUE CACHE INTERNAL "Updater alias initialization marker")
