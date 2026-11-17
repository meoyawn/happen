import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Persistent, ordinary form controls let browser password managers fill values
/// directly, including extensions that do not dispatch Flutter input events.
class WebLogin extends StatefulWidget {
  const WebLogin({super.key, required this.server, required this.busy, required this.submit, this.error});
  final String server;
  final bool busy;
  final String? error;
  final void Function(String server, String key) submit;

  @override
  State<WebLogin> createState() => _WebLoginState();
}

class _WebLoginState extends State<WebLogin> {
  web.HTMLFormElement? _form;
  late web.HTMLInputElement _server, _password;
  late web.HTMLButtonElement _button;
  late web.HTMLParagraphElement _error;
  StreamSubscription<web.Event>? _submit;

  void _create(Object element) {
    final form = _form = element as web.HTMLFormElement;
    form..id = 'happen-login'..name = 'happen-login'..method = 'post'
      ..action = '${Uri.base.origin}/'..autocomplete = 'on';
    form.style.cssText = 'box-sizing:border-box;width:100%;height:100%;overflow:auto;'
      'display:flex;align-items:center;justify-content:center;'
      'font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#191c1e;background:#fff;';
    final content = web.HTMLDivElement()..style.cssText = 'box-sizing:border-box;width:100%;max-width:420px;padding:28px;';
    content.append(web.HTMLHeadingElement.h1()..textContent = 'Happen'
      ..style.cssText = 'font-size:30px;font-weight:600;line-height:1.2;margin:0 0 20px;');
    content.append(web.HTMLParagraphElement()..textContent = 'Connect to your server with its owner key.'
      ..style.cssText = 'margin:0 0 28px;');
    _server = web.HTMLInputElement()..id = 'server-url'..name = 'username'..type = 'url'
      ..autocomplete = 'username'..required = true..value = widget.server
      ..autocapitalize = 'none'..spellcheck = false;
    _password = web.HTMLInputElement()..id = 'owner-key'..name = 'password'..type = 'password'
      ..autocomplete = 'current-password'..required = true..autocapitalize = 'none'..spellcheck = false;
    for (final (input, title) in [(_server, 'Server tunnel URL'), (_password, 'Owner key')]) {
      final label = web.HTMLLabelElement()..htmlFor = input.id..textContent = title;
      label.style.cssText = 'display:block;margin:0 0 6px;color:#616569;font-size:14px;';
      input.style.cssText = 'box-sizing:border-box;width:100%;min-width:0;height:48px;'
        'font:inherit;font-size:16px;color:inherit;background:#fff;border:1px solid #b9bdc0;'
        'border-radius:5px;padding:10px 12px;margin:0 0 20px;';
      content..append(label)..append(input);
    }
    _error = web.HTMLParagraphElement()..id = 'login-error'..setAttribute('role', 'alert')
      ..style.cssText = 'color:#c62828;margin:0 0 16px;';
    _password.setAttribute('aria-describedby', _error.id);
    _button = web.HTMLButtonElement()..type = 'submit'
      ..style.cssText = 'width:100%;min-height:44px;border:0;border-radius:24px;background:#191c1e;'
        'color:white;font:inherit;font-weight:600;cursor:pointer;padding:10px 16px;';
    content..append(_error)..append(_button);
    form.append(content);
    _update();
    _submit = form.onSubmit.listen((event) {
      event.preventDefault();
      if (!widget.busy) widget.submit(_server.value, _password.value);
    });
  }

  void _update() {
    if (_form == null) return;
    // Keep controls mounted and readable while authenticating. Disabling or
    // recreating password inputs can discard a password manager's autofill.
    _server.readOnly = _password.readOnly = widget.busy;
    _button..disabled = widget.busy..textContent = widget.busy ? 'Connecting…' : 'Sign in';
    _error..textContent = widget.error ?? ''..toggleAttribute('hidden', widget.error == null);
    _form!.setAttribute('aria-busy', '${widget.busy}');
  }

  @override
  void didUpdateWidget(WebLogin oldWidget) { super.didUpdateWidget(oldWidget); _update(); }

  @override
  void dispose() {
    unawaited(_submit?.cancel());
    if (_form != null) _password.value = '';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(tagName: 'form', onElementCreated: _create);
}
