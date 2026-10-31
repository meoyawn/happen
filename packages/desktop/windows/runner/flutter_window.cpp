#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kShow = 1;
constexpr UINT kQuit = 2;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  auto messenger = flutter_controller_->engine()->messenger();
  lifecycle_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "happen/lifecycle", &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "happen/desktop", &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "activate") {
      ShowMainWindow();
      result->Success();
    } else if (call.method_name() == "openLoginUrl" || call.method_name() == "openMcpLoginUrl") {
      const auto* url = std::get_if<std::string>(call.arguments());
      const bool mcp = call.method_name() == "openMcpLoginUrl";
      const bool allowed = url && (mcp
          ? (url->rfind("https://", 0) == 0 && url->size() > 8) ||
            url->rfind("http://127.0.0.1:", 0) == 0 || url->rfind("http://localhost:", 0) == 0 ||
            url->rfind("http://[::1]:", 0) == 0
          : url->rfind("https://auth.openai.com/", 0) == 0 ||
            url->rfind("https://opencode.ai/", 0) == 0 || url->rfind("https://auth.opencode.ai/", 0) == 0);
      if (!allowed || url->find_first_of("\r\n\\") != std::string::npos) {
        result->Error("invalid_url", "Invalid sign-in URL");
        return;
      }
      const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
          url->data(), static_cast<int>(url->size()), nullptr, 0);
      if (!length) {
        result->Error("invalid_url", "Invalid sign-in URL");
        return;
      }
      std::wstring wide_url(length, L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, url->data(),
          static_cast<int>(url->size()), wide_url.data(), length);
      auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(
          GetHandle(), L"open", wide_url.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      result->Success(flutter::EncodableValue(opened > 32));
    } else {
      result->NotImplemented();
    }
  });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"Happen");
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // The Dart quit handler is installed by the first frame.
    AddTrayIcon();
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_available_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_available_ = false;
  }
  lifecycle_channel_ = nullptr;
  desktop_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Intercept close before Flutter turns the last window's WM_CLOSE into exit.
  if (message == WM_CLOSE) {
    // A missing Explorer notification area must not strand a hidden window.
    ShowWindow(hwnd, tray_available_ ? SW_HIDE : SW_MINIMIZE);
    return 0;
  }
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    AddTrayIcon();
    return 0;
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        break;
      case NIN_SELECT:
      case NIN_KEYSELECT:
        ShowMainWindow();
        break;
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  tray_available_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
  if (tray_available_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
  SetFocus(flutter_controller_->view()->GetNativeWindow());
}

void FlutterWindow::ShowTrayMenu() {
  POINT cursor;
  GetCursorPos(&cursor);
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kShow, L"Show");
  AppendMenuW(menu, MF_STRING, kQuit, L"Quit");
  SetForegroundWindow(GetHandle());
  const auto action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
      cursor.x, cursor.y, 0, GetHandle(), nullptr);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (action == kShow) {
    ShowMainWindow();
  } else if (action == kQuit) {
    // Dart closes its session, database, and embedded server before native exit.
    lifecycle_channel_->InvokeMethod("quit", nullptr);
  }
}
