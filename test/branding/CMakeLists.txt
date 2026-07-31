find_package(Python3 REQUIRED COMPONENTS Interpreter)

add_test(
  NAME split-capture-branding
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/validate-branding.py"
)
