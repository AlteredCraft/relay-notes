#!/usr/bin/env ruby
# Wires Relay NotesTests/WhisperModelStoreTests.swift into the Relay NotesTests
# target. The test target is a regular PBXGroup (not a synchronized one), so
# new test files must be added explicitly.
#
# Pattern matched from the existing test file refs in project.pbxproj:
#   path = "Relay NotesTests/<file>" (relative to project root)
#   name = "<file>" (display name in Xcode)
#   sourceTree = "<group>"
require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] || 'Relay Notes.xcodeproj'
GROUP_NAME   = 'Relay NotesTests'
TARGET_NAME  = 'Relay NotesTests'
FILE_NAME    = 'WhisperModelStoreTests.swift'
FILE_PATH    = "#{GROUP_NAME}/#{FILE_NAME}"

project = Xcodeproj::Project.open(PROJECT_PATH)

group = project.main_group.find_subpath(GROUP_NAME, false)
abort("Group #{GROUP_NAME} not found") unless group

target = project.targets.find { |t| t.name == TARGET_NAME }
abort("Target #{TARGET_NAME} not found") unless target

if group.files.any? { |f| f.path == FILE_PATH }
  puts "#{FILE_NAME} already in #{GROUP_NAME} group — skipping group add"
else
  file_ref = group.new_file(FILE_NAME)
  file_ref.path = FILE_PATH
  file_ref.name = FILE_NAME
end

file_ref = group.files.find { |f| f.path == FILE_PATH }
abort("File ref missing after add") unless file_ref

unless target.source_build_phase.files_references.include?(file_ref)
  target.add_file_references([file_ref])
end

project.save
puts "OK — #{FILE_NAME} wired into #{TARGET_NAME}"
