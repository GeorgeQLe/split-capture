add_executable(dual-capture-logic-test dual-capture-logic-test.cpp)

target_compile_features(dual-capture-logic-test PRIVATE cxx_std_17)
target_include_directories(dual-capture-logic-test PRIVATE "${CMAKE_SOURCE_DIR}/frontend/utility")

add_test(NAME dual-capture-logic COMMAND dual-capture-logic-test)

find_program(JQ_EXECUTABLE jq)
find_program(FFPROBE_EXECUTABLE ffprobe)
find_program(BASH_EXECUTABLE NAMES bash bash.exe HINTS "$ENV{ProgramFiles}/Git/bin")
if(JQ_EXECUTABLE AND FFPROBE_EXECUTABLE AND BASH_EXECUTABLE)
  get_filename_component(FFPROBE_DIRECTORY "${FFPROBE_EXECUTABLE}" DIRECTORY)
  add_test(
    NAME dual-capture-validator-initialization-error
    COMMAND
      "${BASH_EXECUTABLE}"
      "${CMAKE_CURRENT_SOURCE_DIR}/validate-session.sh"
      "--expect"
      "initialization-error"
      "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/initialization-error"
  )
  set_tests_properties(
    dual-capture-validator-initialization-error
    PROPERTIES ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${FFPROBE_DIRECTORY}"
  )
endif()

if(JQ_EXECUTABLE AND BASH_EXECUTABLE)
  add_test(
    NAME dual-capture-qualification-finalize
    COMMAND
      "${BASH_EXECUTABLE}"
      "${CMAKE_CURRENT_SOURCE_DIR}/qualification-finalize-test.sh"
      "${CMAKE_CURRENT_SOURCE_DIR}/qualification-runner.sh"
  )
endif()

set_target_properties(dual-capture-logic-test PROPERTIES FOLDER "Tests and Examples")
