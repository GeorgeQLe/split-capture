/******************************************************************************
    Copyright (C) 2026

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
******************************************************************************/

#pragma once

#include <array>
#include <string>
#include <string_view>

enum class MicRoute { Both, Desktop, Camera, Off };

enum class DualCaptureTestFailpoint {
	None,
	Preflight,
	DesktopStart,
	CameraStart,
	Invalid,
};

constexpr DualCaptureTestFailpoint DualCaptureParseTestFailpoint(std::string_view name)
{
	if (name == "preflight") {
		return DualCaptureTestFailpoint::Preflight;
	}
	if (name == "desktop-start") {
		return DualCaptureTestFailpoint::DesktopStart;
	}
	if (name == "camera-start") {
		return DualCaptureTestFailpoint::CameraStart;
	}
	return DualCaptureTestFailpoint::Invalid;
}

constexpr bool DualCaptureMicrophoneRequested(MicRoute route)
{
	return route != MicRoute::Off;
}

constexpr bool DualCaptureMicrophoneRoutesToDesktop(MicRoute route)
{
	return route == MicRoute::Both || route == MicRoute::Desktop;
}

constexpr bool DualCaptureMicrophoneRoutesToCamera(MicRoute route)
{
	return route == MicRoute::Both || route == MicRoute::Camera;
}

enum class DualCaptureSourceState {
	Ready,
	PermissionRequired,
	NotEnumerated,
	NotLive,
};

struct DualCaptureReadiness {
	DualCaptureSourceState desktop = DualCaptureSourceState::NotEnumerated;
	DualCaptureSourceState camera = DualCaptureSourceState::NotEnumerated;
	DualCaptureSourceState microphone = DualCaptureSourceState::NotEnumerated;
	DualCaptureSourceState systemAudio = DualCaptureSourceState::NotEnumerated;
	bool microphoneRequested = true;
	bool systemAudioRequested = true;
	bool outputRootExists = false;
	bool outputRootWritable = false;
	bool standardOutputActive = false;
};

enum class DualCaptureBlocker {
	None,
	DesktopPermission,
	DesktopNotEnumerated,
	DesktopNotLive,
	CameraPermission,
	CameraNotEnumerated,
	CameraNotLive,
	MicrophonePermission,
	MicrophoneNotEnumerated,
	MicrophoneNotLive,
	SystemAudioPermission,
	SystemAudioNotEnumerated,
	SystemAudioNotLive,
	OutputRootMissing,
	OutputRootNotWritable,
	StandardOutputActive,
};

constexpr DualCaptureBlocker DualCaptureBlockingReason(const DualCaptureReadiness &readiness)
{
	const auto sourceBlocker = [](DualCaptureSourceState state, DualCaptureBlocker permission,
				      DualCaptureBlocker enumeration, DualCaptureBlocker live) {
		switch (state) {
		case DualCaptureSourceState::Ready:
			return DualCaptureBlocker::None;
		case DualCaptureSourceState::PermissionRequired:
			return permission;
		case DualCaptureSourceState::NotEnumerated:
			return enumeration;
		case DualCaptureSourceState::NotLive:
			return live;
		}
		return live;
	};

	if (const auto blocker = sourceBlocker(readiness.desktop, DualCaptureBlocker::DesktopPermission,
					       DualCaptureBlocker::DesktopNotEnumerated,
					       DualCaptureBlocker::DesktopNotLive);
	    blocker != DualCaptureBlocker::None) {
		return blocker;
	}
	if (const auto blocker = sourceBlocker(readiness.camera, DualCaptureBlocker::CameraPermission,
					       DualCaptureBlocker::CameraNotEnumerated,
					       DualCaptureBlocker::CameraNotLive);
	    blocker != DualCaptureBlocker::None) {
		return blocker;
	}
	if (readiness.microphoneRequested) {
		if (const auto blocker = sourceBlocker(readiness.microphone, DualCaptureBlocker::MicrophonePermission,
						       DualCaptureBlocker::MicrophoneNotEnumerated,
						       DualCaptureBlocker::MicrophoneNotLive);
		    blocker != DualCaptureBlocker::None) {
			return blocker;
		}
	}
	if (readiness.systemAudioRequested) {
		if (const auto blocker = sourceBlocker(readiness.systemAudio, DualCaptureBlocker::SystemAudioPermission,
						       DualCaptureBlocker::SystemAudioNotEnumerated,
						       DualCaptureBlocker::SystemAudioNotLive);
		    blocker != DualCaptureBlocker::None) {
			return blocker;
		}
	}
	if (!readiness.outputRootExists) {
		return DualCaptureBlocker::OutputRootMissing;
	}
	if (!readiness.outputRootWritable) {
		return DualCaptureBlocker::OutputRootNotWritable;
	}
	if (readiness.standardOutputActive) {
		return DualCaptureBlocker::StandardOutputActive;
	}
	return DualCaptureBlocker::None;
}

enum class MacSystemAudioBackend {
	Unavailable,
	ScreenCaptureKit,
	CoreAudio,
};

constexpr MacSystemAudioBackend DualCaptureMacSystemAudioBackend(bool screenCaptureKitRegistered,
								 bool coreAudioDeviceEnumerated)
{
	if (screenCaptureKitRegistered) {
		return MacSystemAudioBackend::ScreenCaptureKit;
	}
	if (coreAudioDeviceEnumerated) {
		return MacSystemAudioBackend::CoreAudio;
	}
	return MacSystemAudioBackend::Unavailable;
}

inline std::string DualCaptureOutputError(std::string_view role, const char *message, std::string_view fallback)
{
	std::string result(role);
	result += ": ";
	result += message && *message ? message : fallback;
	return result;
}

inline constexpr std::array<std::string_view, 2> DualCaptureInitializationMediaArtifacts{
	"desktop.mp4",
	"camera.mp4",
};

enum class DualCaptureShutdownAction {
	StopAndWait,
	ReleaseResources,
	AlreadyShutdown,
};

enum class DualCaptureShutdownOutcome {
	Idle,
	Completed,
	TimedOut,
};

class DualCaptureShutdownLifecycle {
public:
	constexpr DualCaptureShutdownAction Begin(bool recorderBusy)
	{
		if (begun) {
			return DualCaptureShutdownAction::AlreadyShutdown;
		}
		begun = true;
		wasBusy = recorderBusy;
		return recorderBusy ? DualCaptureShutdownAction::StopAndWait
				    : DualCaptureShutdownAction::ReleaseResources;
	}

	constexpr DualCaptureShutdownOutcome Finish(bool recorderStillBusy) const
	{
		if (!wasBusy) {
			return DualCaptureShutdownOutcome::Idle;
		}
		return recorderStillBusy ? DualCaptureShutdownOutcome::TimedOut : DualCaptureShutdownOutcome::Completed;
	}

private:
	bool begun = false;
	bool wasBusy = false;
};

constexpr bool DualCaptureStopCompletesManifest(std::string_view reason)
{
	return reason == "user" || reason == "application_exit";
}
