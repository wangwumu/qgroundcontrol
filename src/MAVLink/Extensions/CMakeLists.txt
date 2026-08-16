# ============================================================================
# VTOL Safety Extensions
# Custom MAVLink messages (msg_id 80000-80003) for VTOL flight safety management
# ============================================================================

target_sources(
    ${CMAKE_PROJECT_NAME}
    PRIVATE
        VTOLSafetyMessages.h
        VTOLExtensions.cc
        VTOLExtensions.h
        VTOLExtensionsEnums.h
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
