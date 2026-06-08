# CMakeList.txt : CMake project for odb-dump
# Minimal CLI exercising libOdbDesign against an ODB++ archive.

add_executable(odb-dump odb_dump.cpp)

# Link to the parser library. OdbDesign already brings in Crow, Protobuf,
# Utils, ZLIB transitively as PUBLIC link interface.
target_link_libraries(odb-dump PRIVATE OdbDesign)
