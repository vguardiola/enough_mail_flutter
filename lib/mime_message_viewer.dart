import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail_flutter/enough_mail_flutter.dart';
import 'package:enough_mail_flutter/mime_media_provider.dart';
import 'package:enough_mail_html/enough_mail_html.dart';
import 'package:enough_media/enough_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;
import 'package:webview_flutter/webview_flutter.dart';

/// Viewer for mime message contents
class MimeMessageViewer extends StatefulWidget {
  final MimeMessage mimeMessage;
  final int maxImageWidth;
  final bool adjustHeight;
  final bool blockExternalImages;
  final String emptyMessageText;
  final FutureOr<NavigationDecision> Function(NavigationRequest) navigationDelegate;
  final Future Function(Uri mailto, MimeMessage mimeMessage) mailtoDelegate;
  final Future Function(InteractiveMediaWidget mediaViewer) showMediaDelegate;

  /// Creates a new mime message viewer
  /// [mimeMessage] The message with loaded message contents.
  /// [adjustHeight] Should the webview measure itself and adapt its size? This defaults to `true`.
  /// [blockExternalImages]  Should external images be prevented from loaded? This defaults to `false`.
  /// [emptyMessageText] The default text that should be shown for empty messages.
  /// [navigationDelegate] Browser navigation delegate in case the implementation wants to take over full control about links.
  /// [mailtoDelegate] Handler for mailto: links. Typically you will want to open a new compose view prepulated with a `MessageBuilder.prepareMailtoBasedMessage(uri,from)` instance.
  /// [showMediaDelegate] Handler for showing the given media widget, typically in its own screen
  /// Optionally specify the [maxImageWidth] to set the maximum width for embedded images.
  MimeMessageViewer({
    Key key,
    @required this.mimeMessage,
    this.adjustHeight = true,
    this.blockExternalImages = false,
    this.emptyMessageText,
    this.navigationDelegate,
    this.mailtoDelegate,
    this.showMediaDelegate,
    this.maxImageWidth,
  }) : super(key: key);

  @override
  State<MimeMessageViewer> createState() {
    if (mimeMessage.mediaType?.isImage == true) {
      return _ImageViewerState();
    } else {
      return _HtmlViewerState();
    }
  }
}

class _HtmlGenerationArguments {
  final MimeMessage mimeMessage;
  final bool blockExternalImages;
  final String emptyMessageText;
  final int maxImageWidth;

  _HtmlGenerationArguments(this.mimeMessage, this.blockExternalImages, this.emptyMessageText, this.maxImageWidth);
}

class _HtmlViewerState extends State<MimeMessageViewer> {
  double _screenHeight;
  WebViewController _webViewController;
  double _webViewHeight;
  String _base64EncodedHtml;
  bool _wereExternalImagesBlocked;
  bool _isGenerating;
  Widget _mediaView;

  @override
  void initState() {
    generateHtml(widget.blockExternalImages);
    super.initState();
  }

  void generateHtml(bool blockExternalImages) async {
    _wereExternalImagesBlocked = blockExternalImages;
    _isGenerating = true;
    final args = _HtmlGenerationArguments(
        widget.mimeMessage, blockExternalImages, widget.emptyMessageText, widget.maxImageWidth);
    _base64EncodedHtml = await compute(_generateHtmlImpl, args);
    if (mounted) {
      setState(() {
        _isGenerating = false;
      });
    }
  }

  static String _generateHtmlImpl(_HtmlGenerationArguments args) {
    final html = args.mimeMessage.transformToHtml(
      blockExternalImages: args.blockExternalImages,
      emptyMessageText: args.emptyMessageText,
      maxImageWidth: args.maxImageWidth,
    );
    return 'data:text/html;base64,' + base64Encode(const Utf8Encoder().convert(html));
  }

  @override
  Widget build(BuildContext context) {
    if (_mediaView != null) {
      return WillPopScope(
        child: _mediaView,
        onWillPop: () {
          setState(() {
            _mediaView = null;
          });
          return Future.value(false);
        },
      );
    }
    if (_isGenerating) {
      return Container(child: CircularProgressIndicator());
    }
    _screenHeight = MediaQuery.of(context).size.height;
    if (widget.blockExternalImages != _wereExternalImagesBlocked) {
      generateHtml(widget.blockExternalImages);
    }
    if (widget.adjustHeight) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedHeight) {
            constraints = constraints.copyWith(maxHeight: _webViewHeight ?? _screenHeight);
          }
          return ConstrainedBox(
            constraints: constraints,
            child: buildWebVew(),
          );
        },
      );
    } else {
      return buildWebVew();
    }
  }

  WebView buildWebVew() {
    return WebView(
      key: ValueKey(_base64EncodedHtml),
      javascriptMode: JavascriptMode.unrestricted,
      initialUrl: _base64EncodedHtml,
      gestureRecognizers: null,
      onWebViewCreated: (controller) {
        _webViewController = controller;
      },
      navigationDelegate: widget.navigationDelegate ?? handleNavigationProcess,
      onPageFinished: widget.adjustHeight
          ? (url) async {
              var scrollHeightText = await _webViewController.evaluateJavascript('document.body.scrollHeight');
              double height = double.tryParse(scrollHeightText);
              if ((height != null) && mounted) {
                // && (height < screenHeight)) {
                // allow to scroll web pages further than the screen height, this
                // can lead to crashes but we have to live with that for the moment,
                // until it is fixed by either Flutter or the webview_flutter plugin
                setState(() => _webViewHeight = height + 5);
              }
            }
          : null,
    );
  }

  FutureOr<NavigationDecision> handleNavigationProcess(NavigationRequest request) async {
    if (widget.mailtoDelegate != null && request.url.startsWith('mailto:')) {
      final mailto = Uri.parse(request.url);
      await widget.mailtoDelegate(mailto, widget.mimeMessage);
      return NavigationDecision.prevent;
    }
    if (request.url.startsWith('cid://')) {
      // show inline part:
      final cid = request.url.substring('cid://'.length);
      final part = widget.mimeMessage.getPartWithContentId(cid);
      if (part != null) {
        final mediaProvider = MimeMediaProviderFactory.fromMime(widget.mimeMessage, part);
        final mediaWidget = InteractiveMediaWidget(
          mediaProvider: mediaProvider,
        );
        if (widget.showMediaDelegate != null) {
          widget.showMediaDelegate(mediaWidget);
        } else {
          setState(() {
            _mediaView = mediaWidget;
          });
        }
      }
      return NavigationDecision.prevent;
    }
    if (await launcher.canLaunch(request.url)) {
      await launcher.launch(request.url);
      return NavigationDecision.prevent;
    } else {
      return NavigationDecision.navigate;
    }
  }
}

/// State for a message with  `Content-Type: image/XXX`
class _ImageViewerState extends State<MimeMessageViewer> {
  bool showFullScreen = false;
  Uint8List imageData;

  @override
  void initState() {
    imageData = widget.mimeMessage.decodeContentBinary();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    if (showFullScreen) {
      final screenHeight = MediaQuery.of(context).size.height;
      return WillPopScope(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedHeight) {
              constraints = constraints.copyWith(maxHeight: screenHeight);
            }
            return ConstrainedBox(
              constraints: constraints,
              child: ImageInteractiveMedia(
                  mediaProvider: MimeMediaProviderFactory.fromMime(widget.mimeMessage, widget.mimeMessage)),
            );
          },
        ),
        onWillPop: () {
          setState(() => showFullScreen = false);
          return Future.value(false);
        },
      );
    } else {
      return TextButton(
        onPressed: () {
          if (widget.showMediaDelegate != null) {
            final mediaProvider = MimeMediaProviderFactory.fromMime(widget.mimeMessage, widget.mimeMessage);
            final mediaWidget = InteractiveMediaWidget(mediaProvider: mediaProvider);
            widget.showMediaDelegate(mediaWidget);
          } else {
            setState(() => showFullScreen = true);
          }
        },
        child: Image.memory(imageData),
      );
    }
  }
}
