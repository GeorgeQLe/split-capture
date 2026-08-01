/******************************************************************************
    Copyright (C) 2026

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
******************************************************************************/

#include "DualCaptureDashboard.hpp"

#include "OBSBasic.hpp"
#include "OBSQTDisplay.hpp"

#include <utility/SimpleOutput.hpp>
#ifdef __APPLE__
#include <utility/platform.hpp>
#endif

#include <QCheckBox>
#include <QCloseEvent>
#include <QComboBox>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEvent>
#include <QEventLoop>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QFrame>
#include <QGuiApplication>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QProgressBar>
#include <QPushButton>
#include <QScreen>
#include <QScrollArea>
#include <QShortcut>
#include <QSignalBlocker>
#include <QStorageInfo>
#include <QThread>
#include <QTimer>
#include <QVBoxLayout>

#include <obs-properties.h>
#include <graphics/graphics.h>

#include <algorithm>
#include <vector>

static std::vector<DualCaptureDevice> CatalogDevices(const char *sourceId, const char *propertyName)
{
	std::vector<DualCaptureDevice> devices;
	OBSDataAutoRelease settings = obs_data_create();
	OBSSourceAutoRelease probe = obs_source_create_private(
		sourceId, (std::string("Dual Capture Catalog ") + sourceId).c_str(), settings);
	OBSProperties properties = probe ? obs_source_properties(probe) : obs_get_source_properties(sourceId);
	if (!properties) {
		return devices;
	}
	obs_property_t *property = obs_properties_get(properties, propertyName);
	if (!property || obs_property_get_type(property) != OBS_PROPERTY_LIST) {
		return devices;
	}
	const enum obs_combo_format format = obs_property_list_format(property);
	const size_t count = obs_property_list_item_count(property);
	for (size_t index = 0; index < count; ++index) {
		const char *name = obs_property_list_item_name(property, index);
		QString id;
		if (format == OBS_COMBO_FORMAT_STRING) {
			const char *value = obs_property_list_item_string(property, index);
			id = QString::fromUtf8(value ? value : "");
		} else if (format == OBS_COMBO_FORMAT_INT) {
			id = QString::number(obs_property_list_item_int(property, index));
		} else {
			continue;
		}
		if (id.isEmpty()) {
			continue;
		}
		devices.push_back({sourceId, propertyName, id.toStdString(),
				   QString::fromUtf8(name ? name : id.toUtf8().constData()).toStdString()});
	}
	return devices;
}

static void AddCatalogItems(QComboBox *combo, const char *sourceId, const char *propertyName)
{
	for (const DualCaptureDevice &device : CatalogDevices(sourceId, propertyName)) {
		QVariantMap data;
		data.insert(QStringLiteral("source"), QString::fromStdString(device.sourceId));
		data.insert(QStringLiteral("property"), QString::fromStdString(device.property));
		data.insert(QStringLiteral("id"), QString::fromStdString(device.id));
		combo->addItem(QString::fromStdString(device.name), data);
	}
}

static DualCaptureDevice SelectedDevice(QComboBox *combo)
{
	const QVariantMap data = combo->currentData().toMap();
	return {data.value(QStringLiteral("source")).toString().toStdString(),
		data.value(QStringLiteral("property")).toString().toStdString(),
		data.value(QStringLiteral("id")).toString().toStdString(), combo->currentText().toStdString()};
}

static void RestoreSelection(QComboBox *combo, const char *savedId)
{
	if (!savedId || !*savedId) {
		return;
	}
	for (int index = 0; index < combo->count(); ++index) {
		if (combo->itemData(index).toMap().value(QStringLiteral("id")).toString() ==
		    QString::fromUtf8(savedId)) {
			combo->setCurrentIndex(index);
			return;
		}
	}
}

static QString HumanBytes(uint64_t bytes)
{
	const double gib = static_cast<double>(bytes) / (1024.0 * 1024.0 * 1024.0);
	return QStringLiteral("%1 GB").arg(gib, 0, 'f', 2);
}

static QString BlockingReasonText(DualCaptureBlocker blocker)
{
	switch (blocker) {
	case DualCaptureBlocker::None:
		return {};
	case DualCaptureBlocker::DesktopPermission:
		return QTStr("DualCapture.ScreenPermissionRequired");
	case DualCaptureBlocker::DesktopNotEnumerated:
		return QTStr("DualCapture.DisplayNotEnumerated");
	case DualCaptureBlocker::DesktopNotLive:
		return QTStr("DualCapture.DisplayNotLive");
	case DualCaptureBlocker::CameraPermission:
		return QTStr("DualCapture.CameraPermissionRequired");
	case DualCaptureBlocker::CameraNotEnumerated:
		return QTStr("DualCapture.CameraNotEnumerated");
	case DualCaptureBlocker::CameraNotLive:
		return QTStr("DualCapture.CameraNotLive");
	case DualCaptureBlocker::MicrophonePermission:
		return QTStr("DualCapture.MicrophonePermissionRequired");
	case DualCaptureBlocker::MicrophoneNotEnumerated:
		return QTStr("DualCapture.MicrophoneNotEnumerated");
	case DualCaptureBlocker::MicrophoneNotLive:
		return QTStr("DualCapture.MicrophoneNotLive");
	case DualCaptureBlocker::SystemAudioPermission:
		return QTStr("DualCapture.SystemAudioPermissionRequired");
	case DualCaptureBlocker::SystemAudioNotEnumerated:
		return QTStr("DualCapture.SystemAudioNotEnumerated");
	case DualCaptureBlocker::SystemAudioNotLive:
		return QTStr("DualCapture.SystemAudioNotLive");
	case DualCaptureBlocker::OutputRootMissing:
		return QTStr("DualCapture.InvalidFolder");
	case DualCaptureBlocker::OutputRootNotWritable:
		return QTStr("DualCapture.FolderNotWritable");
	case DualCaptureBlocker::StandardOutputActive:
		return QTStr("DualCapture.OtherOutputActive");
	}
	return {};
}

DualCaptureDashboard::DualCaptureDashboard(OBSBasic *main_)
	: QDialog(main_),
	  main(main_),
	  desktopSelector(new QComboBox(this)),
	  cameraSelector(new QComboBox(this)),
	  microphoneSelector(new QComboBox(this)),
	  routeSelector(new QComboBox(this)),
	  desktopAudio(new QCheckBox(QTStr("DualCapture.DesktopAudio"), this)),
	  outputPath(new QLineEdit(this)),
	  desktopStatus(new QLabel(this)),
	  cameraStatus(new QLabel(this)),
	  audioWarning(new QLabel(this)),
	  storageEstimate(new QLabel(this)),
	  recordingStats(new QLabel(this)),
	  microphoneMeter(new QProgressBar(this)),
	  systemMeter(new QProgressBar(this)),
	  browseButton(new QPushButton(QTStr("Browse"), this)),
	  refreshDevicesButton(new QPushButton(QTStr("DualCapture.RefreshDevices"), this)),
	  fullScreenButton(new QPushButton(QTStr("DualCapture.FullScreen"), this)),
	  recordButton(new QPushButton(QTStr("DualCapture.Start"), this)),
	  advancedButton(new QPushButton(QTStr("DualCapture.AdvancedOBS"), this)),
	  screenPermissionButton(new QPushButton(this)),
	  cameraPermissionButton(new QPushButton(this)),
	  microphonePermissionButton(new QPushButton(this)),
	  timer(new QTimer(this))
{
	setWindowTitle(QTStr("DualCapture.Title"));
	setMinimumSize(720, 600);
	setModal(false);
	setWindowFlag(Qt::Window, true);
	setWindowFlag(Qt::WindowTitleHint, true);
	setWindowFlag(Qt::WindowSystemMenuHint, true);
	setWindowFlag(Qt::WindowMinimizeButtonHint, true);
	setWindowFlag(Qt::WindowMaximizeButtonHint, true);
	setWindowFlag(Qt::WindowCloseButtonHint, true);
	if (QScreen *screen = QGuiApplication::primaryScreen()) {
		const QSize available = screen->availableGeometry().size();
		resize(std::min(900, available.width() - 40), std::min(820, available.height() - 40));
	}

	auto *contents = new QWidget(this);
	auto *heading = new QLabel(QTStr("DualCapture.Heading"), contents);
	QFont headingFont = heading->font();
	headingFont.setPointSize(headingFont.pointSize() + 6);
	headingFont.setBold(true);
	heading->setFont(headingFont);
	auto *description = new QLabel(QTStr("DualCapture.Description"), contents);
	description->setWordWrap(true);

	auto makePreview = [this](const QString &title, const QString &detail, QComboBox *selector, QLabel *status,
				  QPushButton *permissionButton, PreviewState &state) {
		auto *box = new QGroupBox(title, this);
		auto *layout = new QVBoxLayout(box);
		state.display = new OBSQTDisplay(box);
		state.display->setMinimumHeight(135);
		state.display->setStyleSheet(QStringLiteral("background: #17191d; border: 1px solid #343942;"));
		PreviewState *statePtr = &state;
		connect(state.display, &OBSQTDisplay::DisplayCreated, this, [statePtr](OBSQTDisplay *display) {
			obs_display_add_draw_callback(display->GetDisplay(), DualCaptureDashboard::DrawPreview,
						      statePtr);
		});
		layout->addWidget(state.display);
		layout->addWidget(selector);
		auto *resolution = new QLabel(detail, box);
		resolution->setStyleSheet(QStringLiteral("color: #aeb4bf;"));
		layout->addWidget(resolution);
		status->setWordWrap(true);
		layout->addWidget(status);
		layout->addWidget(permissionButton);
		return box;
	};

	auto *previews = new QHBoxLayout;
	previews->addWidget(makePreview(QTStr("DualCapture.Desktop"), QTStr("DualCapture.DesktopResolution"),
					desktopSelector, desktopStatus, screenPermissionButton, desktopPreview));
	previews->addWidget(makePreview(QTStr("DualCapture.Camera"), QTStr("DualCapture.CameraResolution"),
					cameraSelector, cameraStatus, cameraPermissionButton, cameraPreview));

	auto *audioBox = new QGroupBox(QTStr("DualCapture.Audio"), this);
	auto *audioForm = new QFormLayout(audioBox);
	routeSelector->addItem(QTStr("DualCapture.RouteBoth"), static_cast<int>(MicRoute::Both));
	routeSelector->addItem(QTStr("DualCapture.RouteDesktop"), static_cast<int>(MicRoute::Desktop));
	routeSelector->addItem(QTStr("DualCapture.RouteCamera"), static_cast<int>(MicRoute::Camera));
	routeSelector->addItem(QTStr("DualCapture.RouteOff"), static_cast<int>(MicRoute::Off));
	microphoneMeter->setRange(0, 100);
	microphoneMeter->setValue(0);
	microphoneMeter->setTextVisible(false);
	systemMeter->setRange(0, 100);
	systemMeter->setValue(0);
	systemMeter->setTextVisible(false);
	audioForm->addRow(QTStr("DualCapture.Microphone"), microphoneSelector);
	audioForm->addRow(QString(), microphonePermissionButton);
	audioForm->addRow(QTStr("DualCapture.MicrophoneRoute"), routeSelector);
	audioForm->addRow(QString(), desktopAudio);
	audioForm->addRow(QTStr("DualCapture.MicrophoneLevel"), microphoneMeter);
	audioForm->addRow(QTStr("DualCapture.SystemLevel"), systemMeter);
	audioWarning->setWordWrap(true);
	audioForm->addRow(audioWarning);

	auto *outputBox = new QGroupBox(QTStr("DualCapture.Output"), this);
	auto *outputLayout = new QVBoxLayout(outputBox);
	auto *pathLayout = new QHBoxLayout;
	pathLayout->addWidget(outputPath, 1);
	pathLayout->addWidget(browseButton);
	outputLayout->addLayout(pathLayout);
	storageEstimate->setWordWrap(true);
	outputLayout->addWidget(storageEstimate);
	recordingStats->setWordWrap(true);
	outputLayout->addWidget(recordingStats);

	auto *buttonLayout = new QHBoxLayout;
	buttonLayout->addWidget(advancedButton);
	buttonLayout->addWidget(refreshDevicesButton);
	buttonLayout->addWidget(fullScreenButton);
	buttonLayout->addStretch();
	recordButton->setMinimumHeight(48);
	recordButton->setMinimumWidth(240);
	buttonLayout->addWidget(recordButton);

	for (QWidget *control :
	     {static_cast<QWidget *>(desktopSelector), static_cast<QWidget *>(cameraSelector),
	      static_cast<QWidget *>(microphoneSelector), static_cast<QWidget *>(routeSelector),
	      static_cast<QWidget *>(outputPath), static_cast<QWidget *>(browseButton),
	      static_cast<QWidget *>(refreshDevicesButton), static_cast<QWidget *>(fullScreenButton),
	      static_cast<QWidget *>(screenPermissionButton), static_cast<QWidget *>(cameraPermissionButton),
	      static_cast<QWidget *>(microphonePermissionButton)}) {
		control->setMinimumHeight(28);
	}

	auto *contentLayout = new QVBoxLayout(contents);
	contentLayout->addWidget(heading);
	contentLayout->addWidget(description);
	contentLayout->addLayout(previews);
	contentLayout->addWidget(audioBox);
	contentLayout->addWidget(outputBox);
	contentLayout->addLayout(buttonLayout);
	contentLayout->addStretch();

	auto *scrollArea = new QScrollArea(this);
	scrollArea->setWidgetResizable(true);
	scrollArea->setFrameShape(QFrame::NoFrame);
	scrollArea->setWidget(contents);
	auto *layout = new QVBoxLayout(this);
	layout->setContentsMargins(0, 0, 0, 0);
	layout->addWidget(scrollArea);

	PopulateSources();
	LoadSettings();
	connect(desktopSelector, &QComboBox::currentIndexChanged, this, [this] {
		RebuildProbes();
		RefreshReadiness();
	});
	connect(cameraSelector, &QComboBox::currentIndexChanged, this, [this] {
		RebuildProbes();
		RefreshReadiness();
	});
	connect(microphoneSelector, &QComboBox::currentIndexChanged, this, [this] {
		RebuildProbes();
		RefreshReadiness();
	});
	connect(routeSelector, &QComboBox::currentIndexChanged, this, [this] {
		RebuildProbes();
		RefreshReadiness();
	});
	connect(desktopAudio, &QCheckBox::toggled, this, [this] {
		RebuildProbes();
		RefreshReadiness();
	});
	connect(outputPath, &QLineEdit::textChanged, this, [this] { RefreshReadiness(); });
	connect(browseButton, &QPushButton::clicked, this, [this] { Browse(); });
	connect(refreshDevicesButton, &QPushButton::clicked, this, [this] { RefreshDevices(); });
	connect(fullScreenButton, &QPushButton::clicked, this, [this] { ToggleFullScreen(); });
	auto *fullScreenShortcut = new QShortcut(QKeySequence(Qt::Key_F11), this);
	fullScreenShortcut->setAutoRepeat(false);
	connect(fullScreenShortcut, &QShortcut::activated, this, [this] { ToggleFullScreen(); });
	auto *exitFullScreenShortcut = new QShortcut(QKeySequence(Qt::Key_Escape), this);
	exitFullScreenShortcut->setAutoRepeat(false);
	connect(exitFullScreenShortcut, &QShortcut::activated, this, [this] {
		if (isFullScreen()) {
			ExitFullScreen();
		}
	});
	connect(recordButton, &QPushButton::clicked, this, [this] { ToggleRecording(); });
	connect(advancedButton, &QPushButton::clicked, this, [this] {
		if (recorder.Busy()) {
			return;
		}
		advancedRequested = true;
		hide();
		main->show();
		main->raise();
		main->activateWindow();
	});
#ifdef __APPLE__
	connect(screenPermissionButton, &QPushButton::clicked, this, [this] {
		const MacPermissionStatus status = CheckPermission(kScreenCapture);
		if (!screenPermissionRequested) {
			screenPermissionRequested = true;
			RequestPermission(kScreenCapture);
		} else if (status != kPermissionAuthorized) {
			OpenMacOSPrivacyPreferences("ScreenCapture");
		}
		UpdatePermissionActions();
		RebuildProbes();
		RefreshReadiness();
	});
	connect(cameraPermissionButton, &QPushButton::clicked, this, [this] {
		if (CheckPermission(kVideoDeviceAccess) == kPermissionNotDetermined) {
			RequestPermission(kVideoDeviceAccess);
		} else {
			OpenMacOSPrivacyPreferences("Camera");
		}
		UpdatePermissionActions();
		RebuildProbes();
		RefreshReadiness();
	});
	connect(microphonePermissionButton, &QPushButton::clicked, this, [this] {
		if (CheckPermission(kAudioDeviceAccess) == kPermissionNotDetermined) {
			RequestPermission(kAudioDeviceAccess);
		} else {
			OpenMacOSPrivacyPreferences("Microphone");
		}
		UpdatePermissionActions();
		RebuildProbes();
		RefreshReadiness();
	});
#else
	screenPermissionButton->hide();
	cameraPermissionButton->hide();
	microphonePermissionButton->hide();
#endif
	connect(timer, &QTimer::timeout, this, [this] { UpdateStats(); });
	timer->start(500);
	UpdatePermissionActions();
	RebuildProbes();
	RefreshReadiness();
}

DualCaptureDashboard::~DualCaptureDashboard()
{
	Shutdown();
	if (outputsDisabled) {
		main->EnableOutputs(true);
	}
}

void DualCaptureDashboard::Shutdown(int timeoutMilliseconds)
{
	const DualCaptureShutdownAction action = shutdownLifecycle.Begin(recorder.Busy());
	if (action == DualCaptureShutdownAction::AlreadyShutdown) {
		return;
	}

	timer->stop();
	if (action == DualCaptureShutdownAction::StopAndWait) {
		recorder.Stop("application_exit");
		QElapsedTimer elapsed;
		elapsed.start();
		while (recorder.Busy() && elapsed.elapsed() < timeoutMilliseconds) {
			recorder.CheckOutputs();
			if (!recorder.Busy()) {
				break;
			}
			QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 10);
			QThread::msleep(10);
		}
		recorder.CheckOutputs();
	}

	if (shutdownLifecycle.Finish(recorder.Busy()) == DualCaptureShutdownOutcome::TimedOut) {
		recorder.ShutdownTimedOut();
	}
	ClearPreviews();
	ClearAudioProbes();
}

void DualCaptureDashboard::PopulateSources()
{
#ifdef __APPLE__
	AddCatalogItems(desktopSelector, "screen_capture", "display_uuid");
	AddCatalogItems(cameraSelector, "macos-avcapture", "device");
	AddCatalogItems(microphoneSelector, "coreaudio_input_capture", "device_id");
#elif defined(_WIN32)
	AddCatalogItems(desktopSelector, "monitor_capture", "monitor_id");
	AddCatalogItems(cameraSelector, "dshow_input", "video_device_id");
	AddCatalogItems(microphoneSelector, "wasapi_input_capture", "device_id");
#endif
}

void DualCaptureDashboard::LoadSettings()
{
	config_t *config = main->Config();
	RestoreSelection(desktopSelector, config_get_string(config, "DualCapture", "DesktopId"));
	RestoreSelection(cameraSelector, config_get_string(config, "DualCapture", "CameraId"));
	RestoreSelection(microphoneSelector, config_get_string(config, "DualCapture", "MicrophoneId"));
	const char *path = config_get_string(config, "DualCapture", "OutputRoot");
	if (!path || !*path) {
		path = config_get_string(config, "SimpleOutput", "FilePath");
	}
	outputPath->setText(QString::fromUtf8(path ? path : ""));
	const int route = static_cast<int>(config_get_int(config, "DualCapture", "MicrophoneRoute"));
	routeSelector->setCurrentIndex(std::clamp(route, 0, 3));
	desktopAudio->setChecked(!config_has_user_value(config, "DualCapture", "DesktopAudio") ||
				 config_get_bool(config, "DualCapture", "DesktopAudio"));
}

void DualCaptureDashboard::SaveSettings()
{
	const DualCaptureConfig value = CurrentConfig();
	config_t *config = main->Config();
	config_set_string(config, "DualCapture", "DesktopId", value.desktop.id.c_str());
	config_set_string(config, "DualCapture", "CameraId", value.camera.id.c_str());
	config_set_string(config, "DualCapture", "MicrophoneId", value.microphone.id.c_str());
	config_set_string(config, "DualCapture", "OutputRoot", value.outputRoot.c_str());
	config_set_int(config, "DualCapture", "MicrophoneRoute", routeSelector->currentIndex());
	config_set_bool(config, "DualCapture", "DesktopAudio", value.desktopAudio);
	config_save_safe(config, "tmp", nullptr);
}

DualCaptureConfig DualCaptureDashboard::CurrentConfig() const
{
	DualCaptureConfig config;
	config.desktop = SelectedDevice(desktopSelector);
	config.camera = SelectedDevice(cameraSelector);
	config.microphone = SelectedDevice(microphoneSelector);
#ifdef __APPLE__
	const bool screenCaptureKitRegistered = obs_get_source_output_flags("sck_audio_capture") & OBS_SOURCE_AUDIO;
	const auto coreAudioDevices = screenCaptureKitRegistered
					      ? std::vector<DualCaptureDevice>{}
					      : CatalogDevices("coreaudio_output_capture", "device_id");
	switch (DualCaptureMacSystemAudioBackend(screenCaptureKitRegistered, !coreAudioDevices.empty())) {
	case MacSystemAudioBackend::ScreenCaptureKit:
		config.systemAudio = {"sck_audio_capture", "", "", "macOS Desktop Audio"};
		break;
	case MacSystemAudioBackend::CoreAudio:
		config.systemAudio = coreAudioDevices.front();
		break;
	case MacSystemAudioBackend::Unavailable:
		break;
	}
#elif defined(_WIN32)
	config.systemAudio = {"wasapi_output_capture", "device_id", "default", "Default System Audio"};
#endif
	config.outputRoot = outputPath->text().toStdString();
	config.micRoute = static_cast<MicRoute>(routeSelector->currentData().toInt());
	config.desktopAudio = desktopAudio->isChecked();
	const char *configuredEncoder = config_get_string(main->Config(), "SimpleOutput", "RecEncoder");
	config.videoEncoderId = get_simple_output_encoder(configuredEncoder ? configuredEncoder : SIMPLE_ENCODER_X264);
	return config;
}

void DualCaptureDashboard::Browse()
{
	const QString directory =
		QFileDialog::getExistingDirectory(this, QTStr("DualCapture.OutputFolder"), outputPath->text());
	if (!directory.isEmpty()) {
		outputPath->setText(directory);
	}
}

void DualCaptureDashboard::RefreshDevices()
{
	if (recorder.Busy() || deviceRefreshPending) {
		return;
	}

	const std::string desktopId = SelectedDevice(desktopSelector).id;
	const std::string cameraId = SelectedDevice(cameraSelector).id;
	const std::string microphoneId = SelectedDevice(microphoneSelector).id;

	deviceRefreshPending = true;
	refreshDevicesButton->setEnabled(false);
	recordButton->setEnabled(false);
	ClearPreviews();
	ClearAudioProbes();
	/*
	 * DirectShow releases camera sources asynchronously. Re-enumerating and
	 * rebuilding immediately can race the old preview and leave the replacement
	 * disconnected, so coalesce refresh requests and wait for device release.
	 */
	QTimer::singleShot(1000, this, [this, desktopId, cameraId, microphoneId] {
		deviceRefreshPending = false;
		if (recorder.Busy()) {
			return;
		}

		const QSignalBlocker blockDesktop(desktopSelector);
		const QSignalBlocker blockCamera(cameraSelector);
		const QSignalBlocker blockMicrophone(microphoneSelector);
		desktopSelector->clear();
		cameraSelector->clear();
		microphoneSelector->clear();
		PopulateSources();
		RestoreSelection(desktopSelector, desktopId.c_str());
		RestoreSelection(cameraSelector, cameraId.c_str());
		RestoreSelection(microphoneSelector, microphoneId.c_str());

		refreshDevicesButton->setEnabled(true);
		RebuildProbes();
		RefreshReadiness();
	});
}

void DualCaptureDashboard::ToggleFullScreen()
{
	if (isFullScreen()) {
		ExitFullScreen();
		return;
	}

	restoreMaximizedAfterFullScreen = isMaximized();
	showFullScreen();
	UpdateFullScreenButton();
}

void DualCaptureDashboard::ExitFullScreen()
{
	if (!isFullScreen()) {
		return;
	}

	if (restoreMaximizedAfterFullScreen) {
		showMaximized();
	} else {
		showNormal();
	}
	UpdateFullScreenButton();
}

void DualCaptureDashboard::UpdateFullScreenButton()
{
	fullScreenButton->setText(
		QTStr(isFullScreen() ? "DualCapture.ExitFullScreen" : "DualCapture.FullScreen"));
}

void DualCaptureDashboard::RefreshReadiness()
{
	if (recorder.Busy()) {
		return;
	}
	const MicRoute route = static_cast<MicRoute>(routeSelector->currentData().toInt());
	bool screenPermission = true;
	bool cameraPermission = true;
	bool microphonePermission = true;
#ifdef __APPLE__
	screenPermission = CheckPermission(kScreenCapture) == kPermissionAuthorized;
	cameraPermission = CheckPermission(kVideoDeviceAccess) == kPermissionAuthorized;
	microphonePermission = CheckPermission(kAudioDeviceAccess) == kPermissionAuthorized;
#endif
	const bool desktopReady = screenPermission && desktopPreview.source &&
				  obs_source_get_width(desktopPreview.source) > 0 &&
				  obs_source_get_height(desktopPreview.source) > 0;
	const bool cameraReady = cameraPermission && cameraPreview.source &&
				 obs_source_get_width(cameraPreview.source) > 0 &&
				 obs_source_get_height(cameraPreview.source) > 0;
	const bool microphoneRequested = DualCaptureMicrophoneRequested(route);
	const bool microphoneReady = !microphoneRequested ||
				     (microphonePermission && microphoneProbe && obs_source_active(microphoneProbe) &&
				      obs_source_audio_active(microphoneProbe));
	const bool systemReady = !desktopAudio->isChecked() ||
				 (screenPermission && systemAudioProbe && obs_source_active(systemAudioProbe) &&
				  obs_source_audio_active(systemAudioProbe));
	const QFileInfo folder(outputPath->text());
	const bool folderExists = folder.exists() && folder.isDir();
	DualCaptureReadiness readiness;
	readiness.desktop =
		!screenPermission
			? DualCaptureSourceState::PermissionRequired
			: (SelectedDevice(desktopSelector).sourceId.empty()
				   ? DualCaptureSourceState::NotEnumerated
				   : (desktopReady ? DualCaptureSourceState::Ready : DualCaptureSourceState::NotLive));
	readiness.camera =
		!cameraPermission
			? DualCaptureSourceState::PermissionRequired
			: (SelectedDevice(cameraSelector).sourceId.empty()
				   ? DualCaptureSourceState::NotEnumerated
				   : (cameraReady ? DualCaptureSourceState::Ready : DualCaptureSourceState::NotLive));
	readiness.microphoneRequested = microphoneRequested;
	readiness.microphone = !microphonePermission ? DualCaptureSourceState::PermissionRequired
						     : (SelectedDevice(microphoneSelector).sourceId.empty()
								? DualCaptureSourceState::NotEnumerated
								: (microphoneReady ? DualCaptureSourceState::Ready
										   : DualCaptureSourceState::NotLive));
	const DualCaptureDevice systemAudioDevice = CurrentConfig().systemAudio;
	readiness.systemAudioRequested = desktopAudio->isChecked();
	readiness.systemAudio =
		!screenPermission
			? DualCaptureSourceState::PermissionRequired
			: (systemAudioDevice.sourceId.empty()
				   ? DualCaptureSourceState::NotEnumerated
				   : (systemReady ? DualCaptureSourceState::Ready : DualCaptureSourceState::NotLive));
	readiness.outputRootExists = folderExists;
	readiness.outputRootWritable = folderExists && folder.isWritable();
	readiness.standardOutputActive = main->Active();
	const DualCaptureBlocker blocker = DualCaptureBlockingReason(readiness);
	desktopStatus->setText(QTStr(desktopReady ? "DualCapture.Ready" : "DualCapture.DisplayUnavailable"));
	cameraStatus->setText(QTStr(cameraReady ? "DualCapture.Ready" : "DualCapture.CameraUnavailable"));
	if (route == MicRoute::Both) {
		audioWarning->setText(QTStr("DualCapture.BothExplanation"));
	} else if (!microphoneReady) {
		audioWarning->setText(QTStr("DualCapture.MicrophoneUnavailable"));
	} else if (!systemReady) {
		audioWarning->setText(QStringLiteral("Desktop audio is requested but its live source is not active."));
	} else {
		audioWarning->setText(QTStr("DualCapture.AudioReady"));
	}

	QStorageInfo storage(outputPath->text());
	const double estimatedGiBPerHour = 16.2;
	if (storage.isValid() && storage.isReady()) {
		storageEstimate->setText(QTStr("DualCapture.StorageEstimate")
						 .arg(QString::number(estimatedGiBPerHour, 'f', 1),
						      HumanBytes(storage.bytesAvailable())));
	} else {
		storageEstimate->setText(QTStr("DualCapture.InvalidFolder"));
	}
	const QString blockingReason = BlockingReasonText(blocker);
	recordingStats->setText(blockingReason.isEmpty() ? QTStr("DualCapture.IdleStats") : blockingReason);
	recordButton->setEnabled(blockingReason.isEmpty());
	microphoneMeter->setValue(microphoneProbeLevel.load());
	systemMeter->setValue(systemAudioProbeLevel.load());
	UpdatePermissionActions();
}

void DualCaptureDashboard::ToggleRecording()
{
	if (recorder.Busy()) {
		if (recorder.Stopping()) {
			return;
		}
		recorder.Stop("user");
		recordButton->setEnabled(false);
		recordButton->setText(QStringLiteral("Finalizing…"));
		return;
	}
	if (main->Active()) {
		QMessageBox::warning(this, QTStr("DualCapture.Title"), QTStr("DualCapture.OtherOutputActive"));
		return;
	}
	SaveSettings();
	SetRecordingUi(true);
	ClearPreviews();
	ClearAudioProbes();
	std::string error;
	if (!recorder.Start(CurrentConfig(), error)) {
		if (recorder.Busy()) {
			recordButton->setEnabled(false);
			recordButton->setText(QStringLiteral("Finalizing…"));
		} else {
			SetRecordingUi(false);
			RebuildProbes();
		}
		QMessageBox::critical(this, QTStr("Output.StartRecordingFailed"), QString::fromStdString(error));
		RefreshReadiness();
		if (recorder.Busy()) {
			recordButton->setEnabled(false);
		}
		return;
	}
	if (recorder.UsedEncoderFallback()) {
		QMessageBox::warning(this, QTStr("DualCapture.Title"), QTStr("DualCapture.EncoderFallback"));
	}
}

void DualCaptureDashboard::SetRecordingUi(bool recording)
{
	if (recording != outputsDisabled) {
		main->EnableOutputs(!recording);
		outputsDisabled = recording;
	}
	for (QWidget *widget :
	     {static_cast<QWidget *>(desktopSelector), static_cast<QWidget *>(cameraSelector),
	      static_cast<QWidget *>(microphoneSelector), static_cast<QWidget *>(routeSelector),
	      static_cast<QWidget *>(desktopAudio), static_cast<QWidget *>(outputPath),
	      static_cast<QWidget *>(browseButton), static_cast<QWidget *>(refreshDevicesButton),
	      static_cast<QWidget *>(advancedButton),
	      static_cast<QWidget *>(screenPermissionButton), static_cast<QWidget *>(cameraPermissionButton),
	      static_cast<QWidget *>(microphonePermissionButton)}) {
		widget->setEnabled(!recording);
	}
	recordButton->setText(QTStr(recording ? "DualCapture.Stop" : "DualCapture.Start"));
	recordButton->setEnabled(recording);
}

void DualCaptureDashboard::UpdateStats()
{
	if (!recorder.Busy()) {
		if (outputsDisabled) {
			SetRecordingUi(false);
			/*
			 * DirectShow can retain the camera for a short time after the
			 * recording source is released. Recreating the preview
			 * immediately can open a disconnected source that then blocks
			 * the next capture. Keep Start disabled until the backend has
			 * had time to finish releasing the device.
			 */
			QTimer::singleShot(1000, this, [this] {
				if (!recorder.Busy()) {
					RebuildProbes();
					RefreshReadiness();
				}
			});
			if (!recorder.LastError().empty()) {
				QMessageBox::critical(this, QTStr("DualCapture.Title"),
						      QString::fromStdString(recorder.LastError()));
			}
		}
		RefreshReadiness();
		return;
	}
	recorder.CheckOutputs();
	if (!recorder.Busy()) {
		UpdateStats();
		return;
	}
	const DualCaptureStats stats = recorder.Stats();
	microphoneMeter->setValue(stats.microphoneLevel);
	systemMeter->setValue(stats.systemAudioLevel);
	const qint64 totalSeconds = stats.elapsedMilliseconds / 1000;
	recordingStats->setText(QTStr("DualCapture.ActiveStats")
					.arg(QStringLiteral("%1:%2:%3")
						     .arg(totalSeconds / 3600, 2, 10, QLatin1Char('0'))
						     .arg((totalSeconds / 60) % 60, 2, 10, QLatin1Char('0'))
						     .arg(totalSeconds % 60, 2, 10, QLatin1Char('0')),
					     HumanBytes(stats.desktopBytes), HumanBytes(stats.cameraBytes))
					.arg(stats.desktopDroppedFrames)
					.arg(stats.cameraDroppedFrames));
	if (recorder.Stopping()) {
		recordButton->setEnabled(false);
		recordButton->setText(QStringLiteral("Finalizing…"));
	}
}

static OBSSourceAutoRelease CreatePreviewSource(const DualCaptureDevice &device, const char *name, bool camera)
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
	if (camera) {
		obs_data_set_bool(settings, "enable_audio", false);
		obs_data_set_bool(settings, "use_preset", true);
		obs_data_set_string(settings, "preset", "AVCaptureSessionPreset1920x1080");
	}
#elif defined(_WIN32)
	if (camera) {
		obs_data_set_int(settings, "audio_output_mode", 0);
	}
#else
	(void)camera;
#endif
	return obs_source_create_private(device.sourceId.c_str(), name, settings);
}

void DualCaptureDashboard::ClearPreviews()
{
	for (PreviewState *preview : {&desktopPreview, &cameraPreview}) {
		if (preview->source) {
			obs_source_dec_showing(preview->source);
		}
		preview->source = nullptr;
	}
}

void DualCaptureDashboard::ClearAudioProbes()
{
	if (microphoneProbeVolmeter) {
		obs_volmeter_destroy(microphoneProbeVolmeter);
		microphoneProbeVolmeter = nullptr;
	}
	if (systemAudioProbeVolmeter) {
		obs_volmeter_destroy(systemAudioProbeVolmeter);
		systemAudioProbeVolmeter = nullptr;
	}
	if (microphoneProbe) {
		obs_source_dec_active(microphoneProbe);
	}
	if (systemAudioProbe) {
		obs_source_dec_active(systemAudioProbe);
	}
	microphoneProbe = nullptr;
	systemAudioProbe = nullptr;
	microphoneProbeLevel = 0;
	systemAudioProbeLevel = 0;
}

void DualCaptureDashboard::UpdatePreviews()
{
	if (recorder.Busy()) {
		return;
	}
	ClearPreviews();
	desktopPreview.source =
		CreatePreviewSource(SelectedDevice(desktopSelector), "Dual Capture Desktop Preview", false);
	cameraPreview.source = CreatePreviewSource(SelectedDevice(cameraSelector), "Dual Capture Camera Preview", true);
	for (PreviewState *preview : {&desktopPreview, &cameraPreview}) {
		if (preview->source) {
			obs_source_inc_showing(preview->source);
		}
	}
}

void DualCaptureDashboard::RebuildProbes()
{
	if (recorder.Busy()) {
		return;
	}
	UpdatePreviews();
	ClearAudioProbes();
	const DualCaptureConfig config = CurrentConfig();
	if (DualCaptureMicrophoneRequested(config.micRoute)) {
		microphoneProbe = CreatePreviewSource(config.microphone, "Dual Capture Microphone Probe", false);
	}
	if (config.desktopAudio) {
		systemAudioProbe = CreatePreviewSource(config.systemAudio, "Dual Capture System Audio Probe", false);
	}
	if (microphoneProbe) {
		obs_source_inc_active(microphoneProbe);
		microphoneProbeVolmeter = obs_volmeter_create(OBS_FADER_LOG);
		obs_volmeter_add_callback(microphoneProbeVolmeter, CaptureProbeLevel, &microphoneProbeLevel);
		obs_volmeter_attach_source(microphoneProbeVolmeter, microphoneProbe);
	}
	if (systemAudioProbe) {
		obs_source_inc_active(systemAudioProbe);
		systemAudioProbeVolmeter = obs_volmeter_create(OBS_FADER_LOG);
		obs_volmeter_add_callback(systemAudioProbeVolmeter, CaptureProbeLevel, &systemAudioProbeLevel);
		obs_volmeter_attach_source(systemAudioProbeVolmeter, systemAudioProbe);
	}
}

void DualCaptureDashboard::CaptureProbeLevel(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
					     const float[MAX_AUDIO_CHANNELS], const float[MAX_AUDIO_CHANNELS])
{
	float loudest = -60.0f;
	for (size_t channel = 0; channel < MAX_AUDIO_CHANNELS; ++channel) {
		loudest = std::max(loudest, magnitude[channel]);
	}
	static_cast<std::atomic<int> *>(param)->store(
		std::clamp(static_cast<int>((loudest + 60.0f) * (100.0f / 60.0f)), 0, 100));
}

void DualCaptureDashboard::UpdatePermissionActions()
{
#ifdef __APPLE__
	auto update = [](QPushButton *button, MacPermissionStatus status, bool canRequest) {
		button->setVisible(status != kPermissionAuthorized);
		if (status == kPermissionNotDetermined || canRequest) {
			button->setText(QStringLiteral("Request access"));
		} else {
			button->setText(QStringLiteral("Open System Settings"));
		}
	};
	update(screenPermissionButton, CheckPermission(kScreenCapture), !screenPermissionRequested);
	update(cameraPermissionButton, CheckPermission(kVideoDeviceAccess), false);
	update(microphonePermissionButton, CheckPermission(kAudioDeviceAccess), false);
#endif
}

void DualCaptureDashboard::DrawPreview(void *data, uint32_t width, uint32_t height)
{
	auto *preview = static_cast<PreviewState *>(data);
	if (!preview->source) {
		return;
	}
	const uint32_t sourceWidth = std::max(obs_source_get_width(preview->source), 1u);
	const uint32_t sourceHeight = std::max(obs_source_get_height(preview->source), 1u);
	const float scale =
		std::min(static_cast<float>(width) / sourceWidth, static_cast<float>(height) / sourceHeight);
	const int renderWidth = static_cast<int>(sourceWidth * scale);
	const int renderHeight = static_cast<int>(sourceHeight * scale);
	const int x = (static_cast<int>(width) - renderWidth) / 2;
	const int y = (static_cast<int>(height) - renderHeight) / 2;

	gs_viewport_push();
	gs_projection_push();
	gs_ortho(0.0f, static_cast<float>(sourceWidth), 0.0f, static_cast<float>(sourceHeight), -100.0f, 100.0f);
	gs_set_viewport(x, y, renderWidth, renderHeight);
	obs_source_video_render(preview->source);
	gs_projection_pop();
	gs_viewport_pop();
}

bool DualCaptureDashboard::event(QEvent *event)
{
	if (event->type() == QEvent::WindowActivate && !recorder.Busy()) {
		RefreshDevices();
	}
	if (event->type() == QEvent::WindowStateChange) {
		const auto *stateEvent = static_cast<QWindowStateChangeEvent *>(event);
		if (isFullScreen() && !stateEvent->oldState().testFlag(Qt::WindowFullScreen)) {
			restoreMaximizedAfterFullScreen =
				stateEvent->oldState().testFlag(Qt::WindowMaximized);
		}
	}
	const bool handled = QDialog::event(event);
	if (event->type() == QEvent::WindowStateChange) {
		UpdateFullScreenButton();
	}
	return handled;
}

void DualCaptureDashboard::OpenFocused()
{
	advancedRequested = false;
	main->hide();
	show();
	raise();
	activateWindow();
}

void DualCaptureDashboard::closeEvent(QCloseEvent *event)
{
	if (recorder.Busy()) {
		const auto answer =
			QMessageBox::question(this, QTStr("DualCapture.Title"), QTStr("DualCapture.StopOnClose"));
		if (answer != QMessageBox::Yes) {
			event->ignore();
			return;
		}
		if (!recorder.Stopping()) {
			recorder.Stop("user");
		}
		event->ignore();
		return;
	}
	if (!advancedRequested) {
		event->ignore();
		OpenFocused();
		return;
	}
	QDialog::closeEvent(event);
}
