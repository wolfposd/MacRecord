#!/bin/bash

xcodebuild -project MacRecord.xcodeproj -scheme MacRecord \
  -configuration Release -derivedDataPath build build \
  DEVELOPMENT_TEAM=U34SG283KY CODE_SIGN_IDENTITY="Apple Development"

open build/Build/Products/Release 
