#include "DualCaptureLogic.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

static void Check(bool condition, const char *message)
{
	if (condition) {
		return;
	}
	std::cerr << message << '\n';
	std::exit(EXIT_FAILURE);
}

int main()
{
	Check(DualCaptureParseTestFailpoint("preflight") == DualCaptureTestFailpoint::Preflight,
	      "preflight failpoint must parse");
	Check(DualCaptureParseTestFailpoint("desktop-start") == DualCaptureTestFailpoint::DesktopStart,
	      "Desktop start failpoint must parse");
	Check(DualCaptureParseTestFailpoint("camera-start") == DualCaptureTestFailpoint::CameraStart,
	      "Camera start failpoint must parse");
	Check(DualCaptureParseTestFailpoint("other") == DualCaptureTestFailpoint::Invalid,
	      "unknown failpoints must be rejected");

	Check(DualCaptureOutputError("Camera", nullptr, "fallback") == "Camera: fallback",
	      "null OBS errors must use the role-specific fallback");
	Check(DualCaptureOutputError("Desktop", "", "fallback") == "Desktop: fallback",
	      "empty OBS errors must use the role-specific fallback");
	Check(DualCaptureOutputError("Camera", "encoder failed", "fallback") == "Camera: encoder failed",
	      "nonempty OBS errors must be preserved");

	Check(DualCaptureMicrophoneRequested(MicRoute::Both), "Both must request a microphone");
	Check(DualCaptureMicrophoneRequested(MicRoute::Desktop), "Desktop must request a microphone");
	Check(DualCaptureMicrophoneRequested(MicRoute::Camera), "Camera must request a microphone");
	Check(!DualCaptureMicrophoneRequested(MicRoute::Off), "Off must not request a microphone");
	Check(DualCaptureMicrophoneRoutesToDesktop(MicRoute::Both), "Both must route to Desktop");
	Check(DualCaptureMicrophoneRoutesToDesktop(MicRoute::Desktop), "Desktop must route to Desktop");
	Check(!DualCaptureMicrophoneRoutesToDesktop(MicRoute::Camera), "Camera must not route to Desktop");
	Check(!DualCaptureMicrophoneRoutesToDesktop(MicRoute::Off), "Off must not route to Desktop");
	Check(DualCaptureMicrophoneRoutesToCamera(MicRoute::Both), "Both must add Camera audio");
	Check(!DualCaptureMicrophoneRoutesToCamera(MicRoute::Desktop), "Desktop must produce video-only Camera");
	Check(DualCaptureMicrophoneRoutesToCamera(MicRoute::Camera), "Camera must add Camera audio");
	Check(!DualCaptureMicrophoneRoutesToCamera(MicRoute::Off), "Off must produce video-only Camera");

	Check(DualCaptureMacSystemAudioBackend(true, true) == MacSystemAudioBackend::ScreenCaptureKit,
	      "ScreenCaptureKit must take precedence");
	Check(DualCaptureMacSystemAudioBackend(false, true) == MacSystemAudioBackend::CoreAudio,
	      "CoreAudio must be the fallback");
	Check(DualCaptureMacSystemAudioBackend(false, false) == MacSystemAudioBackend::Unavailable,
	      "missing system-audio sources must remain unavailable");

	DualCaptureReadiness ready;
	ready.desktop = DualCaptureSourceState::Ready;
	ready.camera = DualCaptureSourceState::Ready;
	ready.microphone = DualCaptureSourceState::Ready;
	ready.systemAudio = DualCaptureSourceState::Ready;
	ready.outputRootExists = true;
	ready.outputRootWritable = true;
	Check(DualCaptureBlockingReason(ready) == DualCaptureBlocker::None, "all-ready state must permit Start");

	struct SourceCase {
		DualCaptureSourceState state;
		DualCaptureBlocker desktop;
		DualCaptureBlocker camera;
		DualCaptureBlocker microphone;
		DualCaptureBlocker systemAudio;
	};
	const SourceCase sourceCases[] = {
		{DualCaptureSourceState::PermissionRequired, DualCaptureBlocker::DesktopPermission,
		 DualCaptureBlocker::CameraPermission, DualCaptureBlocker::MicrophonePermission,
		 DualCaptureBlocker::SystemAudioPermission},
		{DualCaptureSourceState::NotEnumerated, DualCaptureBlocker::DesktopNotEnumerated,
		 DualCaptureBlocker::CameraNotEnumerated, DualCaptureBlocker::MicrophoneNotEnumerated,
		 DualCaptureBlocker::SystemAudioNotEnumerated},
		{DualCaptureSourceState::NotLive, DualCaptureBlocker::DesktopNotLive, DualCaptureBlocker::CameraNotLive,
		 DualCaptureBlocker::MicrophoneNotLive, DualCaptureBlocker::SystemAudioNotLive},
	};
	for (const SourceCase &sourceCase : sourceCases) {
		auto state = ready;
		state.desktop = sourceCase.state;
		Check(DualCaptureBlockingReason(state) == sourceCase.desktop, "Desktop state blocker mismatch");
		state = ready;
		state.camera = sourceCase.state;
		Check(DualCaptureBlockingReason(state) == sourceCase.camera, "Camera state blocker mismatch");
		state = ready;
		state.microphone = sourceCase.state;
		Check(DualCaptureBlockingReason(state) == sourceCase.microphone, "microphone state blocker mismatch");
		state.microphoneRequested = false;
		Check(DualCaptureBlockingReason(state) == DualCaptureBlocker::None,
		      "unrequested microphone must not block Start");
		state = ready;
		state.systemAudio = sourceCase.state;
		Check(DualCaptureBlockingReason(state) == sourceCase.systemAudio,
		      "system-audio state blocker mismatch");
		state.systemAudioRequested = false;
		Check(DualCaptureBlockingReason(state) == DualCaptureBlocker::None,
		      "unrequested system audio must not block Start");
	}

	auto state = ready;
	state.outputRootExists = false;
	Check(DualCaptureBlockingReason(state) == DualCaptureBlocker::OutputRootMissing,
	      "missing output root must block Start");
	state = ready;
	state.outputRootWritable = false;
	Check(DualCaptureBlockingReason(state) == DualCaptureBlocker::OutputRootNotWritable,
	      "unwritable output root must block Start");
	state = ready;
	state.standardOutputActive = true;
	Check(DualCaptureBlockingReason(state) == DualCaptureBlocker::StandardOutputActive,
	      "standard output must block Start");

	Check(DualCaptureInitializationMediaArtifacts.size() == 2,
	      "initialization cleanup must target exactly two media artifacts");
	Check(DualCaptureInitializationMediaArtifacts[0] == "desktop.mp4" &&
		      DualCaptureInitializationMediaArtifacts[1] == "camera.mp4",
	      "initialization cleanup must retain session.json and target only newly created media");
}
