if(SPLIT_OBS_ENABLE_CUSTOM_UPDATER)
  if(NOT SPLIT_OBS_UPDATE_FEED_URL OR NOT SPLIT_OBS_UPDATE_PUBLIC_KEY)
    message(
      FATAL_ERROR
        "SPLIT_OBS_ENABLE_CUSTOM_UPDATER requires SPLIT_OBS_UPDATE_FEED_URL and SPLIT_OBS_UPDATE_PUBLIC_KEY"
    )
  endif()

  set(SPARKLE_APPCAST_URL "${SPLIT_OBS_UPDATE_FEED_URL}")
  set(SPARKLE_PUBLIC_KEY "${SPLIT_OBS_UPDATE_PUBLIC_KEY}")

  find_library(SPARKLE Sparkle)
  mark_as_advanced(SPARKLE)
  target_sources(
    obs-studio
    PRIVATE
      utility/MacUpdateThread.cpp
      utility/MacUpdateThread.hpp
      utility/OBSSparkle.hpp
      utility/OBSSparkle.mm
      utility/OBSUpdateDelegate.h
      utility/OBSUpdateDelegate.mm
  )
  set_source_files_properties(utility/OBSSparkle.mm PROPERTIES COMPILE_OPTIONS -fobjc-arc)

  target_link_libraries(obs-studio PRIVATE "$<LINK_LIBRARY:FRAMEWORK,${SPARKLE}>")

  if(OBS_BETA GREATER 0 OR OBS_RELEASE_CANDIDATE GREATER 0)
    set(SPARKLE_UPDATE_INTERVAL 3600) # 1 hour
  else()
    set(SPARKLE_UPDATE_INTERVAL 86400) # 24 hours
  endif()

  set(
    SPARKLE_INFO_PLIST
    "<key>SUFeedURL</key>
	<string>${SPARKLE_APPCAST_URL}</string>
	<key>SUPublicEDKey</key>
	<string>${SPARKLE_PUBLIC_KEY}</string>
	<key>SUScheduledCheckInterval</key>
	<integer>${SPARKLE_UPDATE_INTERVAL}</integer>"
  )

  target_enable_feature(obs-studio "Sparkle updater" ENABLE_SPARKLE_UPDATER)

  include(cmake/feature-macos-update.cmake)
else()
  # Never inherit OBS Studio's official feed or signing key. A fork build must
  # opt in with its own signed update channel above.
  set(SPARKLE_APPCAST_URL "")
  set(SPARKLE_PUBLIC_KEY "")
  set(SPARKLE_INFO_PLIST "")
  target_disable_feature(obs-studio "Sparkle updater")
endif()
