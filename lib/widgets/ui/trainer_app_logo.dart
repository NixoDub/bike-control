import 'package:shadcn_flutter/shadcn_flutter.dart';

/// A trainer app's logo: the bundled [asset], falling back to [url] when the
/// asset can't be loaded.
///
/// The fallback exists for logos added after a build shipped: an over-the-air
/// patch can't add assets, so on older builds the asset is missing and the
/// logo is fetched from the website instead. With no [url], or when that
/// fails as well, an empty box of the same size keeps the layout steady.
class TrainerAppLogo extends StatelessWidget {
  const TrainerAppLogo({super.key, required this.asset, this.url, this.width, this.height, this.fit});

  final String asset;
  final String? url;
  final double? width;
  final double? height;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, _, _) {
        final url = this.url;
        if (url == null) return _empty;
        return Image.network(
          url,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (context, _, _) => _empty,
        );
      },
    );
  }

  Widget get _empty => SizedBox(width: width, height: height);
}
