#!/usr/bin/env ruby
# Wires an existing file under Relay NotesTests/ into the Relay NotesTests
# target: `ruby scripts/add_test_file.rb WhisperFooTests.swift`. The test
# target is a regular PBXGroup (not a synchronized one), so new test files
# must be added explicitly. Generalizes add_whisper_model_store_tests.rb,
# which is kept as the T1.2b historical artifact.
#
# Pattern matched from the existing test file refs in project.pbxproj:
#   path = "Relay NotesTests/<file>" (relative to project root)
#   name = "<file>" (display name in Xcode)
#   sourceTree = "<group>"
require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] || 'Relay Notes.xcodeproj'
GROUP_NAME   = 'Relay NotesTests'
TARGET_NAME  = 'Relay NotesTests'

FILE_NAME = ARGV[0]
abort("Usage: ruby scripts/add_test_file.rb <FileName.swift>") unless FILE_NAME
FILE_PATH = "#{GROUP_NAME}/#{FILE_NAME}"
abort("#{FILE_PATH} does not exist on disk — create the file first") unless File.exist?(FILE_PATH)

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
