/******************************************************************************
    Copyright (C) 2026

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
******************************************************************************/

#include "DualCaptureRecorder.hpp"

#include "audio-encoders.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QUuid>

#include <graphics/vec2.h>

#include <algorithm>
#ifdef ENABLE_DUAL_CAPTURE_TEST_HOOKS
static std::atomic<DualCaptureTestFailpoint> testFailpoint{DualCaptureTestFailpoint::None};
#endif

static constexpr uint32_t MixerMask(uint32_t mixer)
{
	return 1u << mixer;
}

static QString RouteName(MicRoute route)
{
	switch (route) {
	case MicRoute::Both:
		return QStringLiteral("both");
	case MicRoute::Desktop:
		return QStringLiteral("desktop");
	case MicRoute::Camera:
		return QStringLiteral("camera");
	case MicRoute::Off:
		return QStringLiteral("off");
	}
	return QStringLiteral("off");
}

DualCaptureRecorder::~DualCaptureRecorder()
{
	Stop("shutdown");
	CheckOutputs();
	if (Busy()) {
		ShutdownTimedOut();
	}
}

bool DualCaptureRecorder::SetTestFailpoint(const char *name)
{
#ifdef ENABLE_DUAL_CAPTURE_TEST_HOOKS
	const DualCaptureTestFailpoint value = DualCaptureParseTestFailpoint(name);
	if (value == DualCaptureTestFailpoint::Invalid) {
		return false;
	}
	testFailpoint.store(value);
	return true;
#else
	(void)name;
	return false;
#endif
}

bool DualCaptureRecorder::ConsumeTestFailpoint(DualCaptureTestFailpoint failpoint)
{
#ifdef ENABLE_DUAL_CAPTURE_TEST_HOOKS
	DualCaptureTestFailpoint expected = failpoint;
	return testFailpoint.compare_exchange_strong(expected, DualCaptureTestFailpoint::None);
#else
	(void)failpoint;
	return false;
#endif
}

OBSSourceAutoRelease DualCaptureRecorder::CreateManagedSource(const DualCaptureDevice &device, const char *name,
							      bool disableEmbeddedAudio)
{
	if (device.sourceId.empty() || (device.property.empty() != device.id.empty())) {
		return nullptr;
	}

	OBSDataAutoRelease settings = obs_data_create();
	if (!device.property.empty()) {
		obs_data_set_string(settings, device.property.c_str(), device.id.c_str());
	}

#ifdef __APPLE__
	if (device.sourceId == "screen_capture") {
		obs_data_set_bool(settings, "capture_audio", false);
	}
	if (disableEmbeddedAudio) {
		obs_data_set_bool(settings, "enable_audio", false);
		obs_data_set_bool(settings, "use_preset", true);
		obs_data_set_string(settings, "preset", "AVCaptureSessionPreset1920x1080");
	}
#elif defined(_WIN32)
	if (disableEmbeddedAudio) {
		obs_data_set_int(settings, "audio_output_mode", 0);
		obs_data_set_int(settings, "res_type", 1);
		obs_data_set_string(settings, "resolution", "1920x1080");
		obs_data_set_int(settings, "frame_interval", 333333);
	}
#endif

	return obs_source_create_private(device.sourceId.c_str(), name, settings);
}

bool DualCaptureRecorder::BuildRole(RoleOutput &role, obs_source_t *source, const char *roleName, uint32_t width,
				    uint32_t height, const std::string &encoderId, std::string &error)
{
	role.width = width;
	role.height = height;
	role.scene = obs_scene_create_private((std::string("Dual Capture ") + roleName).c_str());
	if (!role.scene) {
		error = std::string("Could not create the private ") + roleName + " scene.";
		return false;
	}
	role.sceneSource = obs_source_get_ref(obs_scene_get_source(role.scene));

	obs_sceneitem_t *item = obs_scene_add(role.scene, source);
	if (!item) {
		error = std::string("Could not add the managed ") + roleName + " source.";
		return false;
	}
	vec2 bounds = {static_cast<float>(width), static_cast<float>(height)};
	obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
	obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
	obs_sceneitem_set_bounds(item, &bounds);

	obs_video_info ovi = {};
	if (!obs_get_video_info(&ovi)) {
		error = "OBS video is not initialized.";
		return false;
	}
	ovi.base_width = ovi.output_width = width;
	ovi.base_height = ovi.output_height = height;
	ovi.fps_num = currentConfig.fpsNumerator;
	ovi.fps_den = currentConfig.fpsDenominator;

	role.canvas = obs_canvas_create_private((std::string("Dual Capture ") + roleName + " Canvas").c_str(), &ovi,
						DEVICE | MIX_AUDIO);
	if (!role.canvas) {
		error = std::string("Could not create the ") + roleName + " canvas.";
		return false;
	}
	obs_canvas_set_channel(role.canvas, 0, role.sceneSource);

	OBSDataAutoRelease videoSettings = obs_data_create();
	obs_data_set_int(videoSettings, "keyint_sec", 2);
	obs_data_set_int(videoSettings, "bitrate", roleName[0] == 'D' ? 24000 : 12000);
	const std::string encoderName = std::string("dual_capture_") + roleName + "_video";
	role.videoEncoder = obs_video_encoder_create(encoderId.c_str(), encoderName.c_str(), videoSettings, nullptr);
	if (!role.videoEncoder && encoderId != "obs_x264") {
		role.videoEncoder = obs_video_encoder_create("obs_x264", encoderName.c_str(), videoSettings, nullptr);
		encoderFallback = role.videoEncoder != nullptr;
	}
	if (!role.videoEncoder) {
		error = std::string("Could not create a video encoder for ") + roleName + ".";
		return false;
	}
	obs_encoder_set_video(role.videoEncoder, obs_canvas_get_video(role.canvas));
	if (!obs_encoder_set_group(role.videoEncoder, encoderGroup.get())) {
		error = "Could not synchronize the Desktop and Camera video encoders.";
		return false;
	}
	return true;
}

bool DualCaptureRecorder::AddAudioEncoder(RoleOutput &role, uint32_t mixer, const char *name, std::string &error)
{
	OBSDataAutoRelease settings = obs_data_create();
	obs_data_set_int(settings, "bitrate", 192);
	const char *aacId = GetSimpleAACEncoderForBitrate(192);
	OBSEncoderAutoRelease encoder = obs_audio_encoder_create(aacId, name, settings, mixer, nullptr);
	if (!encoder) {
		error = std::string("Could not create AAC track '") + name + "'.";
		return false;
	}
	obs_encoder_set_name(encoder, name);
	obs_encoder_set_audio(encoder, obs_get_audio());
	role.audioEncoders.emplace_back(std::move(encoder));
	return true;
}

void DualCaptureRecorder::RouteAudio()
{
	uint32_t microphoneMixers = 0;
	if (DualCaptureMicrophoneRoutesToDesktop(currentConfig.micRoute)) {
		microphoneMixers |= MixerMask(DesktopPlayback) | MixerMask(IsolatedMicrophone);
	}
	if (DualCaptureMicrophoneRoutesToCamera(currentConfig.micRoute)) {
		microphoneMixers |= MixerMask(CameraPlayback);
	}
	if (microphoneSource) {
		obs_source_set_audio_mixers(microphoneSource, microphoneMixers);
	}

	const uint32_t systemMixers =
		currentConfig.desktopAudio ? MixerMask(DesktopPlayback) | MixerMask(IsolatedSystemAudio) : 0;
	if (systemAudioSource) {
		obs_source_set_audio_mixers(systemAudioSource, systemMixers);
	}
	obs_source_set_audio_mixers(cameraSource, 0);
}

bool DualCaptureRecorder::Start(const DualCaptureConfig &config, std::string &error)
{
	if (Busy()) {
		error = "Dual capture is already active.";
		return false;
	}
	const QFileInfo outputRootInfo(QString::fromStdString(config.outputRoot));
	if (!outputRootInfo.exists() || !outputRootInfo.isDir() || !outputRootInfo.isWritable()) {
		error = "Choose an existing output folder.";
		return false;
	}

	currentConfig = config;
	lastError.clear();
	pendingStopReason.clear();
	stopping = false;
	encoderFallback = false;
	startedAt = QDateTime::currentDateTimeUtc();
	firstDesktopVideoNs = 0;
	firstCameraVideoNs = 0;
	sessionId = QUuid::createUuid().toString(QUuid::WithoutBraces);
	const QString folderName = QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd_HH-mm-ss"));
	QDir outputRoot(QString::fromStdString(config.outputRoot));
	if (!outputRoot.mkdir(folderName) || !outputRoot.cd(folderName)) {
		error = "Could not create the recording session folder.";
		return false;
	}
	sessionDirectory = outputRoot.absolutePath();
	manifestPath = outputRoot.filePath(QStringLiteral("session.json"));

	desktopSource = CreateManagedSource(config.desktop, "Dual Capture Desktop", false);
	cameraSource = CreateManagedSource(config.camera, "Dual Capture Camera", true);
	if (!desktopSource || !cameraSource) {
		error = "The selected display or camera is unavailable. Check permissions and reconnect the device.";
		FailInitialization(error);
		return false;
	}
	if (DualCaptureMicrophoneRequested(config.micRoute)) {
		microphoneSource = CreateManagedSource(config.microphone, "Dual Capture Microphone", false);
		if (!microphoneSource) {
			error = "The selected microphone is unavailable or permission was denied.";
			FailInitialization(error);
			return false;
		}
	}
	if (config.desktopAudio) {
		systemAudioSource = CreateManagedSource(config.systemAudio, "Dual Capture System Audio", false);
		if (!systemAudioSource) {
			error = "Desktop audio is enabled but the system-audio source is unavailable.";
			FailInitialization(error);
			return false;
		}
	}
	if (microphoneSource) {
		microphoneVolmeter = obs_volmeter_create(OBS_FADER_LOG);
		obs_volmeter_add_callback(microphoneVolmeter, CaptureLevel, &microphoneLevel);
		obs_volmeter_attach_source(microphoneVolmeter, microphoneSource);
	}
	if (systemAudioSource) {
		systemAudioVolmeter = obs_volmeter_create(OBS_FADER_LOG);
		obs_volmeter_add_callback(systemAudioVolmeter, CaptureLevel, &systemAudioLevel);
		obs_volmeter_attach_source(systemAudioVolmeter, systemAudioSource);
	}

	RouteAudio();
	encoderGroup = std::shared_ptr<obs_encoder_group_t>(obs_encoder_group_create(), obs_encoder_group_destroy);
	if (!encoderGroup) {
		error = "Could not create the synchronized encoder group.";
		FailInitialization(error);
		return false;
	}

	uint32_t desktopWidth = obs_source_get_width(desktopSource);
	uint32_t desktopHeight = obs_source_get_height(desktopSource);
	obs_video_info mainVideo = {};
	obs_get_video_info(&mainVideo);
	if (!desktopWidth || !desktopHeight) {
		desktopWidth = mainVideo.base_width;
		desktopHeight = mainVideo.base_height;
	}

	if (!BuildRole(desktop, desktopSource, "Desktop", desktopWidth, desktopHeight, config.videoEncoderId, error) ||
	    !BuildRole(camera, cameraSource, "Camera", 1920, 1080, config.videoEncoderId, error)) {
		FailInitialization(error);
		return false;
	}

	if (!AddAudioEncoder(desktop, DesktopPlayback, "Desktop Playback Mix", error)) {
		goto fail;
	}
	if (DualCaptureMicrophoneRoutesToDesktop(config.micRoute)) {
		if (!AddAudioEncoder(desktop, IsolatedMicrophone, "Microphone Isolated", error)) {
			goto fail;
		}
	}
	if (config.desktopAudio && !AddAudioEncoder(desktop, IsolatedSystemAudio, "System Audio Isolated", error)) {
		goto fail;
	}
	if (DualCaptureMicrophoneRoutesToCamera(config.micRoute)) {
		if (!AddAudioEncoder(camera, CameraPlayback, "Camera Microphone", error)) {
			goto fail;
		}
	}

	desktop.filename = outputRoot.filePath(QStringLiteral("desktop.mp4"));
	camera.filename = outputRoot.filePath(QStringLiteral("camera.mp4"));
	for (RoleOutput *role : {&desktop, &camera}) {
		OBSDataAutoRelease outputSettings = obs_data_create();
		obs_data_set_string(outputSettings, "path", role->filename.toUtf8().constData());
		obs_data_set_bool(outputSettings, "allow_overwrite", false);
		OBSDataArrayAutoRelease audioNames = obs_data_array_create();
		for (const auto &audio : role->audioEncoders) {
			OBSDataAutoRelease item = obs_data_create();
			obs_data_set_string(item, "name", obs_encoder_get_name(audio));
			obs_data_array_push_back(audioNames, item);
		}
		obs_data_set_array(outputSettings, "audio_names", audioNames);
		const char *outputId = role == &desktop ? "mp4_output" : "split_mp4_video_output";
		role->output = obs_output_create(
			outputId, (std::string("dual_capture_") + (role == &desktop ? "desktop" : "camera")).c_str(),
			outputSettings, nullptr);
		if (!role->output) {
			error = "Hybrid MP4 output is unavailable.";
			goto fail;
		}
		obs_output_add_packet_callback(role->output, CaptureFirstPacket,
					       role == &desktop ? static_cast<void *>(&firstDesktopVideoNs)
								: static_cast<void *>(&firstCameraVideoNs));
		obs_output_set_video_encoder(role->output, role->videoEncoder);
		for (size_t index = 0; index < role->audioEncoders.size(); ++index) {
			obs_output_set_audio_encoder(role->output, role->audioEncoders[index], index);
		}
	}

	if (ConsumeTestFailpoint(DualCaptureTestFailpoint::Preflight)) {
		error = "Desktop: injected preflight failure.";
		goto fail;
	}
	if (!obs_output_can_begin_data_capture(desktop.output, 0)) {
		error = OutputError(desktop.output, "Desktop", "Desktop output failed preflight.");
		goto fail;
	}
	if (!obs_output_can_begin_data_capture(camera.output, 0)) {
		error = OutputError(camera.output, "Camera", "Camera output failed preflight.");
		goto fail;
	}

	WriteManifest(false, "recording");
	if (ConsumeTestFailpoint(DualCaptureTestFailpoint::DesktopStart)) {
		error = "Desktop: injected start failure.";
		goto fail;
	}
	if (!obs_output_start(desktop.output)) {
		error = OutputError(desktop.output, "Desktop", "Desktop output failed to start.");
		goto fail;
	}
	if (ConsumeTestFailpoint(DualCaptureTestFailpoint::CameraStart)) {
		error = "Camera: injected start failure.";
		goto fail;
	}
	if (!obs_output_start(camera.output)) {
		error = OutputError(camera.output, "Camera", "Camera output failed to start.");
		goto fail;
	}
	blog(LOG_INFO, "Dual capture session %s started in '%s'", sessionId.toUtf8().constData(),
	     sessionDirectory.toUtf8().constData());
	return true;

fail:
	if (error.empty()) {
		error = "Dual capture failed to initialize.";
	}
	FailInitialization(error);
	return false;
}

std::string DualCaptureRecorder::OutputError(obs_output_t *output, const char *role, const char *fallback)
{
	const char *message = output ? obs_output_get_last_error(output) : nullptr;
	return DualCaptureOutputError(role, message, fallback);
}

void DualCaptureRecorder::FailInitialization(const std::string &error)
{
	lastError = error;
	WriteManifest(false, "initialization_error");
	bool outputActive = false;
	for (RoleOutput *role : {&desktop, &camera}) {
		if (role->output && obs_output_active(role->output)) {
			outputActive = true;
			obs_output_force_stop(role->output);
		}
	}
	if (outputActive) {
		stopping = true;
		initializationFailureCleanup = true;
		return;
	}
	FinishInitializationFailure();
}

void DualCaptureRecorder::FinishInitializationFailure()
{
	Clear();
	const QDir directory(sessionDirectory);
	for (const std::string_view filename : DualCaptureInitializationMediaArtifacts) {
		QFile::remove(directory.filePath(
			QString::fromUtf8(filename.data(), static_cast<qsizetype>(filename.size()))));
	}
	initializationFailureCleanup = false;
	stopping = false;
}

void DualCaptureRecorder::CaptureFirstPacket(obs_output_t *, encoder_packet *packet, encoder_packet_time *, void *param)
{
	if (packet->type != OBS_ENCODER_VIDEO) {
		return;
	}
	auto *firstPacket = static_cast<std::atomic<int64_t> *>(param);
	int64_t expected = 0;
	firstPacket->compare_exchange_strong(expected, packet->sys_dts_usec * 1000);
}

void DualCaptureRecorder::CaptureLevel(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
				       const float[MAX_AUDIO_CHANNELS], const float[MAX_AUDIO_CHANNELS])
{
	float loudest = -60.0f;
	for (size_t channel = 0; channel < MAX_AUDIO_CHANNELS; ++channel) {
		loudest = std::max(loudest, magnitude[channel]);
	}
	static_cast<std::atomic<int> *>(param)->store(
		std::clamp(static_cast<int>((loudest + 60.0f) * (100.0f / 60.0f)), 0, 100));
}

bool DualCaptureRecorder::Active() const
{
	return (desktop.output && obs_output_active(desktop.output)) ||
	       (camera.output && obs_output_active(camera.output));
}

bool DualCaptureRecorder::Busy() const
{
	return stopping || desktop.output || camera.output;
}

void DualCaptureRecorder::CheckOutputs()
{
	if (initializationFailureCleanup) {
		if ((!desktop.output || !obs_output_active(desktop.output)) &&
		    (!camera.output || !obs_output_active(camera.output))) {
			FinishInitializationFailure();
		}
		return;
	}
	if (stopping) {
		if ((!desktop.output || !obs_output_active(desktop.output)) &&
		    (!camera.output || !obs_output_active(camera.output))) {
			FinishStop();
		}
		return;
	}
	if (!desktop.output || !camera.output) {
		return;
	}
	const bool desktopActive = obs_output_active(desktop.output);
	const bool cameraActive = obs_output_active(camera.output);
	if (desktopActive != cameraActive) {
		const RoleOutput &failed = desktopActive ? camera : desktop;
		const char *role = desktopActive ? "Camera" : "Desktop";
		lastError = OutputError(failed.output, role, "output stopped unexpectedly.");
		Stop("partner_output_error");
	}
}

DualCaptureStats DualCaptureRecorder::Stats() const
{
	DualCaptureStats stats;
	if (desktop.output) {
		stats.desktopBytes = obs_output_get_total_bytes(desktop.output);
		stats.desktopDroppedFrames = obs_output_get_frames_dropped(desktop.output);
		stats.desktopTotalFrames = obs_output_get_total_frames(desktop.output);
	}
	if (camera.output) {
		stats.cameraBytes = obs_output_get_total_bytes(camera.output);
		stats.cameraDroppedFrames = obs_output_get_frames_dropped(camera.output);
		stats.cameraTotalFrames = obs_output_get_total_frames(camera.output);
	}
	if (startedAt.isValid()) {
		stats.elapsedMilliseconds = startedAt.msecsTo(QDateTime::currentDateTimeUtc());
	}
	stats.microphoneLevel = microphoneLevel.load();
	stats.systemAudioLevel = systemAudioLevel.load();
	return stats;
}

void DualCaptureRecorder::Stop(const std::string &reason)
{
	if (!desktop.output && !camera.output) {
		return;
	}
	if (stopping) {
		if (reason != "application_exit") {
			return;
		}
		if (!initializationFailureCleanup && pendingStopReason == "user") {
			pendingStopReason = reason;
		}
	} else {
		stopping = true;
		pendingStopReason = reason;
	}
	const bool force = reason != "user";
	for (RoleOutput *role : {&desktop, &camera}) {
		if (!role->output || !obs_output_active(role->output)) {
			continue;
		}
		if (force) {
			obs_output_force_stop(role->output);
		} else {
			obs_output_stop(role->output);
		}
	}
	CheckOutputs();
}

void DualCaptureRecorder::ShutdownTimedOut()
{
	if (!Busy()) {
		return;
	}
	WriteManifest(false, "shutdown_timeout");
	blog(LOG_WARNING, "Dual capture session %s cleanup timed out during application shutdown",
	     sessionId.toUtf8().constData());
	Clear();
	initializationFailureCleanup = false;
	stopping = false;
	pendingStopReason.clear();
}

void DualCaptureRecorder::FinishStop()
{
	const std::string reason = pendingStopReason.empty() ? "output_error" : pendingStopReason;
	WriteManifest(DualCaptureStopCompletesManifest(reason), reason);
	blog(LOG_INFO, "Dual capture session %s stopped (%s)", sessionId.toUtf8().constData(), reason.c_str());
	Clear();
	stopping = false;
	pendingStopReason.clear();
}

void DualCaptureRecorder::WriteManifest(bool completed, const std::string &stopReason)
{
	if (manifestPath.isEmpty()) {
		return;
	}
	const DualCaptureStats stats = Stats();
	auto deviceJson = [](const DualCaptureDevice &device) {
		return QJsonObject{{QStringLiteral("id"), QString::fromStdString(device.id)},
				   {QStringLiteral("name"), QString::fromStdString(device.name)},
				   {QStringLiteral("source_id"), QString::fromStdString(device.sourceId)}};
	};
	QJsonArray desktopTracks{QJsonObject{{QStringLiteral("track"), 1},
					     {QStringLiteral("name"), QStringLiteral("Desktop Playback Mix")}}};
	int track = 2;
	if (DualCaptureMicrophoneRoutesToDesktop(currentConfig.micRoute)) {
		desktopTracks.append(QJsonObject{{QStringLiteral("track"), track++},
						 {QStringLiteral("name"), QStringLiteral("Microphone Isolated")}});
	}
	if (currentConfig.desktopAudio) {
		desktopTracks.append(QJsonObject{{QStringLiteral("track"), track},
						 {QStringLiteral("name"), QStringLiteral("System Audio Isolated")}});
	}
	QJsonArray cameraTracks;
	if (DualCaptureMicrophoneRoutesToCamera(currentConfig.micRoute)) {
		cameraTracks.append(QJsonObject{{QStringLiteral("track"), 1},
						{QStringLiteral("name"), QStringLiteral("Camera Microphone")}});
	}

	const int64_t desktopPacketNs = firstDesktopVideoNs.load();
	const int64_t cameraPacketNs = firstCameraVideoNs.load();
	QJsonObject root{
		{QStringLiteral("schema_version"), 1},
		{QStringLiteral("session_id"), sessionId},
		{QStringLiteral("started_at_utc"), startedAt.toString(Qt::ISODateWithMs)},
		{QStringLiteral("completed"), completed},
		{QStringLiteral("stop_reason"), QString::fromStdString(stopReason)},
		{QStringLiteral("devices"),
		 QJsonObject{{QStringLiteral("desktop"), deviceJson(currentConfig.desktop)},
			     {QStringLiteral("camera"), deviceJson(currentConfig.camera)},
			     {QStringLiteral("microphone"), deviceJson(currentConfig.microphone)},
			     {QStringLiteral("system_audio"), deviceJson(currentConfig.systemAudio)}}},
		{QStringLiteral("video"),
		 QJsonObject{{QStringLiteral("fps_numerator"), static_cast<int>(currentConfig.fpsNumerator)},
			     {QStringLiteral("fps_denominator"), static_cast<int>(currentConfig.fpsDenominator)},
			     {QStringLiteral("codec"), QStringLiteral("h264")},
			     {QStringLiteral("encoder"), QString::fromStdString(currentConfig.videoEncoderId)},
			     {QStringLiteral("encoder_fallback"), encoderFallback},
			     {QStringLiteral("desktop"),
			      QJsonObject{{QStringLiteral("width"), static_cast<int>(desktop.width)},
					  {QStringLiteral("height"), static_cast<int>(desktop.height)},
					  {QStringLiteral("filename"), QStringLiteral("desktop.mp4")}}},
			     {QStringLiteral("camera"),
			      QJsonObject{{QStringLiteral("width"), 1920},
					  {QStringLiteral("height"), 1080},
					  {QStringLiteral("filename"), QStringLiteral("camera.mp4")}}}}},
		{QStringLiteral("audio"),
		 QJsonObject{{QStringLiteral("sample_rate"), 48000},
			     {QStringLiteral("codec"), QStringLiteral("aac")},
			     {QStringLiteral("bitrate_kbps"), 192},
			     {QStringLiteral("microphone_route"), RouteName(currentConfig.micRoute)},
			     {QStringLiteral("desktop_audio"), currentConfig.desktopAudio},
			     {QStringLiteral("desktop_tracks"), desktopTracks},
			     {QStringLiteral("camera_tracks"), cameraTracks}}},
		{QStringLiteral("timing"),
		 QJsonObject{{QStringLiteral("first_desktop_packet_ns"),
			      desktopPacketNs ? QJsonValue(static_cast<double>(desktopPacketNs)) : QJsonValue::Null},
			     {QStringLiteral("first_camera_packet_ns"),
			      cameraPacketNs ? QJsonValue(static_cast<double>(cameraPacketNs)) : QJsonValue::Null},
			     {QStringLiteral("nominal_cross_file_offset_ns"),
			      static_cast<double>(cameraPacketNs && desktopPacketNs ? cameraPacketNs - desktopPacketNs
										    : 0)}}},
		{QStringLiteral("duration_ms"), static_cast<double>(stats.elapsedMilliseconds)},
		{QStringLiteral("dropped_frames"), QJsonObject{{QStringLiteral("desktop"), stats.desktopDroppedFrames},
							       {QStringLiteral("camera"), stats.cameraDroppedFrames}}},
		{QStringLiteral("output_errors"), QString::fromStdString(lastError)},
	};
	QSaveFile manifest(manifestPath);
	if (manifest.open(QIODevice::WriteOnly)) {
		manifest.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
		if (!manifest.commit()) {
			blog(LOG_ERROR, "Could not atomically replace dual capture manifest");
		}
	}
}

void DualCaptureRecorder::Clear()
{
	if (microphoneVolmeter) {
		obs_volmeter_destroy(microphoneVolmeter);
		microphoneVolmeter = nullptr;
	}
	if (systemAudioVolmeter) {
		obs_volmeter_destroy(systemAudioVolmeter);
		systemAudioVolmeter = nullptr;
	}
	microphoneLevel = 0;
	systemAudioLevel = 0;
	for (RoleOutput *role : {&desktop, &camera}) {
		if (role->canvas) {
			obs_canvas_set_channel(role->canvas, 0, nullptr);
		}
		*role = RoleOutput{};
	}
	encoderGroup.reset();
	desktopSource = nullptr;
	cameraSource = nullptr;
	microphoneSource = nullptr;
	systemAudioSource = nullptr;
}
