# PROJECT_BRIEF.md

## Overview

Updraft is a macOS PDF viewer built as a **CLI-launched AppKit application** using Swift, SwiftPM, and PDFKit. It is intended to be a fast, scriptable, developer-oriented PDF tool rather than a document-based Cocoa app.

The application is launched from the command line (e.g. `updraft file.pdf`) but presents a full native GUI. It supports multiple windows on the same document, precise navigation, and robust state restoration.

## Core Goals

* Fast startup and deterministic behavior
* CLI-first workflow with GUI rendering
* Multiple independent windows per PDF
* Robust session and per-document state restoration
* Minimal framework usage (AppKit + PDFKit only)

## Non-Goals

* iOS/iPadOS support
* SwiftUI
* Document-based NSDocument architecture
* Annotation editing (for now)

## High-Level Architecture

* **AppDelegate**: Session controller and policy owner
* **UpdraftPDFView**: PDFView subclass for interaction (links, context menu)
* **StateStore**: Persistence layer (Codable + UserDefaults)
* **WindowState / DocumentState**: Serialized session model

The codebase favors explicit control flow and minimal magic over Cocoa conventions.
