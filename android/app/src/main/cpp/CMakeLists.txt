cmake_minimum_required(VERSION 3.22.1)
project(AniAura_discord LANGUAGES CXX)
# NO_DISCORD=ON (CI nightly without the proprietary SDK): no JNI lib. The
# Kotlin no-op stub never calls loadLibrary, so nothing references it.
if(NOT NO_DISCORD)
  find_package(discord_partner_sdk REQUIRED CONFIG)
  add_library(AniAura_discord SHARED discord_presence.cpp)
  target_compile_features(AniAura_discord PRIVATE cxx_std_17)
  target_link_libraries(AniAura_discord discord_partner_sdk::discord_partner_sdk log)
endif()
