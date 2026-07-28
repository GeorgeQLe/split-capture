add_executable(dual-capture-logic-test dual-capture-logic-test.cpp)

target_compile_features(dual-capture-logic-test PRIVATE cxx_std_17)
target_include_directories(dual-capture-logic-test PRIVATE "${CMAKE_SOURCE_DIR}/frontend/utility")

add_test(NAME dual-capture-logic COMMAND dual-capture-logic-test)

find_program(JQ_EXECUTABLE jq)
find_program(FFPROBE_EXECUTABLE ffprobe)
if(JQ_EXECUTABLE AND FFPROBE_EXECUTABLE)
  add_test(
    NAME dual-capture-validator-initialization-error
    COMMAND
      "${CMAKE_CURRENT_SOURCE_DIR}/validate-session.sh"
      "--expect"
      "initialization-error"
      "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/initialization-error"
  )
endif()

if(JQ_EXECUTABLE)
  add_test(
    NAME dual-capture-qualification-finalize
    COMMAND
      "${CMAKE_CURRENT_SOURCE_DIR}/qualification-finalize-test.sh"
      "${CMAKE_CURRENT_SOURCE_DIR}/qualification-runner.sh"
  )
endif()

set_target_properties(dual-capture-logic-test PROPERTIES FOLDER "Tests and Examples")
