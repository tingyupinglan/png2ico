<#
    png2ico.ps1 - convert a PNG to a multi-size ICO with rounded, fully
                  transparent corners.

    Usage:
      powershell -ExecutionPolicy Bypass -File .\png2ico.ps1 .\app_ico.png
      powershell -ExecutionPolicy Bypass -File .\png2ico.ps1 .\app_ico.png .\app.ico
      powershell -ExecutionPolicy Bypass -File .\png2ico.ps1 .\app_ico.png -Sizes 16,24,32,48,64,128,256
      powershell -ExecutionPolicy Bypass -File .\png2ico.ps1 .\app_ico.png -PreviewDir .\preview

    Notes:
      * Background keying: if the PNG has an opaque background (e.g. an AI image
        where the "transparency checkerboard" was painted into the pixels), the
        background connected to the image border is removed first.
      * Rounded corners: the corner radius of the content is detected (falls back
        to 20%) and a rounded-rectangle mask is rasterized per target size.
        Outside the mask alpha=0 (fully transparent); straight edges are
        pixel-aligned, only the 1px arc is anti-aliased.
      * Transparent margins are trimmed, the content is centered, and the ICO is
        written as 32-bit DIB layers with AND masks.
      * -PaddingPercent       Extra padding around the icon, percent of canvas
                             (default 2).
      * -CornerRadiusPercent  Corner radius as percent of the content side:
                             -1 = auto-detect (default), 0 = no rounding,
                             or an explicit value such as 22.
      * -Tolerance            Background color tolerance (0-441, default 75).
                             Increase it if background residue remains.
      * -ForceKeyBackground   Key the background even if alpha is detected.
      * -PreviewDir           Also write a PNG preview for every size.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$InputFile,
    [Parameter(Position = 1)][string]$OutputFile,
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
    [double]$PaddingPercent = 2,
    [double]$CornerRadiusPercent = -1,
    [int]$Tolerance = 75,
    [switch]$ForceKeyBackground,
    [string]$PreviewDir
)

$ErrorActionPreference = 'Stop'

$InputFile = (Resolve-Path -LiteralPath $InputFile).ProviderPath
if (-not $OutputFile) {
    $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, '.ico')
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = Join-Path (Get-Location).ProviderPath $OutputFile
}
if ($PreviewDir -and -not [System.IO.Path]::IsPathRooted($PreviewDir)) {
    $PreviewDir = Join-Path (Get-Location).ProviderPath $PreviewDir
}

$Sizes = @($Sizes | Where-Object { $_ -ge 1 -and $_ -le 256 } | Sort-Object -Unique)
if ($Sizes.Count -eq 0) { throw "Invalid -Sizes value; each size must be between 1 and 256." }

Add-Type -AssemblyName System.Drawing
if (-not ('Png2IcoEngine' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class Png2IcoEngine
{

    public static string Run(string inputPath, string outputPath, int[] sizes,
                             double paddingPercent, double cornerRadiusPercent,
                             int tolerance, bool forceKey, string previewDir)
    {
        using (Bitmap loaded = new Bitmap(inputPath))
        {
            int w = loaded.Width, h = loaded.Height;
            int[] px = LoadPixels(loaded);

            long translucent = 0, borderTranslucent = 0;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int a = (px[y * w + x] >> 24) & 255;
                    if (a < 250)
                    {
                        translucent++;
                        if (x == 0 || y == 0 || x == w - 1 || y == h - 1) borderTranslucent++;
                    }
                }
            bool hasAlpha = translucent > Math.Max(64, (long)w * h / 10000) || borderTranslucent > 0;
            bool keyed = false;
            double removed = 0;
            string mode;

            if (hasAlpha && !forceKey)
            {
                mode = "PNG has an alpha channel; using it as-is";
            }
            else
            {
                bool[] bg;
                keyed = KeyBackground(px, w, h, tolerance, out removed, out bg);
                if (keyed)
                {
                    RemoveSmallComponents(px, w, h);
                    mode = string.Format("Background keyed out ({0:P1} of the image)", removed);
                }
                else
                {
                    mode = "No uniform background found; using the image as-is";
                    px = LoadPixels(loaded);
                }
            }

            int minX, minY, maxX, maxY;
            if (!FindBounds(px, w, h, out minX, out minY, out maxX, out maxY))
                throw new InvalidOperationException("The image is fully transparent; nothing to convert.");
            int bw = maxX - minX + 1, bh = maxY - minY + 1;

            double radiusFrac;
            if (cornerRadiusPercent >= 0)
                radiusFrac = Math.Min(0.5, cornerRadiusPercent / 100.0);
            else
            {
                double r = DetectRadius(px, w, h, minX, minY, maxX, maxY);
                radiusFrac = r / Math.Min(bw, bh);
                if (radiusFrac < 0.05 || radiusFrac > 0.5) radiusFrac = 0.20;
            }

            int inset = Math.Max(1, (int)Math.Round(Math.Max(bw, bh) * 0.0025));
            if (bw - 2 * inset < 4 || bh - 2 * inset < 4) inset = 0;
            int iw = bw - 2 * inset, ih = bh - 2 * inset;
            int side = Math.Max(bw, bh);
            int[] content = new int[side * side];
            int ox = (side - iw) / 2, oy = (side - ih) / 2;
            for (int y = 0; y < ih; y++)
                Array.Copy(px, (minY + inset + y) * w + minX + inset, content, (oy + y) * side + ox, iw);

            // Spread edge colors into the transparent area so resampling
            // does not pick up black or stray colors.
            BleedColor(content, side, side, side);

            // When keying, resample the colors as fully opaque: the shape comes
            // entirely from the rounded mask, so low-alpha pixels never show
            // premultiplication artifacts.
            if (keyed)
                for (int i = 0; i < content.Length; i++)
                    content[i] = (content[i] & 0x00FFFFFF) | unchecked((int)0xFF000000);

            var layers = new List<int[]>(sizes.Length);
            foreach (int size in sizes)
            {
                int pad = (int)Math.Round(size * Math.Max(0, paddingPercent) / 100.0);
                if (pad * 2 >= size) pad = 0;
                int ct = size - 2 * pad;

                int[] cp = ResamplePremul(content, side, side, ct, ct);
                byte[] mask = RoundedMask(size, pad, ct, radiusFrac);
                int[] layer = new int[size * size];
                for (int y = 0; y < ct; y++)
                {
                    int dst = (pad + y) * size + pad;
                    Array.Copy(cp, y * ct, layer, dst, ct);
                }
                for (int i = 0; i < layer.Length; i++)
                {
                    int m = mask[i];
                    if (keyed)
                        layer[i] = (layer[i] & 0x00FFFFFF) | (m << 24);
                    else
                    {
                        int sa = (layer[i] >> 24) & 255;
                        if (m < sa) layer[i] = (layer[i] & 0x00FFFFFF) | (m << 24);
                    }
                }
                layers.Add(layer);
                if (!string.IsNullOrEmpty(previewDir))
                {
                    Directory.CreateDirectory(previewDir);
                    string p = Path.Combine(previewDir,
                        Path.GetFileNameWithoutExtension(outputPath) + "_" + size.ToString() + ".png");
                    using (Bitmap save = ToBitmap(layer, size, size)) save.Save(p, ImageFormat.Png);
                }
            }

            string dir = Path.GetDirectoryName(Path.GetFullPath(outputPath));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            string tmp = outputPath + ".tmp";
            WriteIco(tmp, sizes, layers);
            if (File.Exists(outputPath)) File.Delete(outputPath);
            File.Move(tmp, outputPath);

            string layerInfo = "";
            foreach (int s in sizes) layerInfo += (layerInfo.Length > 0 ? "," : "") + s;
            return mode + Environment.NewLine +
                   string.Format("  Corner radius: {0:P1} of content side", radiusFrac) + Environment.NewLine +
                   "  Content: " + bw + "x" + bh + " -> sizes " + layerInfo + Environment.NewLine +
                   "  Outside corners: alpha=0 (fully transparent)" + Environment.NewLine +
                   "  Output: " + outputPath;
        }
    }

    static int[] LoadPixels(Bitmap bmp)
    {
        int w = bmp.Width, h = bmp.Height;
        using (var b32 = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(b32))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(bmp, new Rectangle(0, 0, w, h));
            }
            var rect = new Rectangle(0, 0, w, h);
            var data = b32.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int[] px = new int[w * h];
            for (int y = 0; y < h; y++)
            {
                IntPtr row = new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride);
                Marshal.Copy(row, px, y * w, w);
            }
            b32.UnlockBits(data);
            return px;
        }
    }

    static Bitmap ToBitmap(int[] px, int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, w, h);
        var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        for (int y = 0; y < h; y++)
        {
            IntPtr row = new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride);
            Marshal.Copy(px, y * w, row, w);
        }
        bmp.UnlockBits(data);
        return bmp;
    }

    static bool FindBounds(int[] px, int w, int h, out int minX, out int minY, out int maxX, out int maxY)
    {
        minX = w; minY = h; maxX = -1; maxY = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (((px[y * w + x] >> 24) & 255) > 0)
                {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
        return maxX >= 0;
    }

    static double DetectRadius(int[] px, int w, int h, int minX, int minY, int maxX, int maxY)
    {
        int bw = maxX - minX + 1, bh = maxY - minY + 1;
        int[] left = new int[h];
        int[] right = new int[h];
        for (int y = 0; y < h; y++)
        {
            left[y] = -1; right[y] = -1;
            for (int x = minX; x <= maxX; x++)
                if (((px[y * w + x] >> 24) & 255) > 0)
                {
                    if (left[y] < 0) left[y] = x;
                    right[y] = x;
                }
        }

        int rMax = Math.Min(bw, bh) / 2 - 1;
        if (rMax < 4) return -1;
        double bestR = -1, bestErr = double.MaxValue;
        for (int r = 3; r <= rMax; r++)
        {
            double err = 0;
            int n = 0;
            for (int dy = 1; dy < r; dy++)
            {
                double pred = r - Math.Sqrt(Math.Max(0.0, (double)r * r - (double)(r - dy) * (r - dy)));
                int ya = minY + dy, yb = maxY - dy;
                if (ya <= maxY)
                {
                    if (left[ya] >= 0) { double g = left[ya] - minX; err += (g - pred) * (g - pred); n++; }
                    if (right[ya] >= 0) { double g = maxX - right[ya]; err += (g - pred) * (g - pred); n++; }
                }
                if (yb >= minY)
                {
                    if (left[yb] >= 0) { double g = left[yb] - minX; err += (g - pred) * (g - pred); n++; }
                    if (right[yb] >= 0) { double g = maxX - right[yb]; err += (g - pred) * (g - pred); n++; }
                }
            }
            if (n < 8) continue;
            err /= n;
            if (err < bestErr) { bestErr = err; bestR = r; }
        }
        return bestR;
    }

    static bool KeyBackground(int[] px, int w, int h, int tolerance, out double removedFraction, out bool[] bg)
    {
        removedFraction = 0;
        bg = null;
        int n = w * h;
        int tol2 = tolerance * tolerance;

        var palette = new List<int>();
        int[] cxs = { 0, w - 8 }, cys = { 0, h - 8 };
        foreach (int cy in cys)
            foreach (int cx in cxs)
            {
                long r = 0, g = 0, b = 0;
                for (int y = cy; y < cy + 8; y++)
                    for (int x = cx; x < cx + 8; x++)
                    {
                        int c = px[y * w + x];
                        r += (c >> 16) & 255; g += (c >> 8) & 255; b += c & 255;
                    }
                palette.Add(unchecked((int)(0xFF000000u | ((uint)(r / 64) << 16) | ((uint)(g / 64) << 8) | (uint)(b / 64))));
            }
        long ar = 0, ag = 0, ab = 0;
        foreach (int c in palette) { ar += (c >> 16) & 255; ag += (c >> 8) & 255; ab += c & 255; }
        palette.Add(unchecked((int)(0xFF000000u | ((uint)(ar / 4) << 16) | ((uint)(ag / 4) << 8) | (uint)(ab / 4))));

        bool[] cand = new bool[n];
        for (int i = 0; i < n; i++)
        {
            int c = px[i];
            int r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
            foreach (int p in palette)
            {
                int dr = r - ((p >> 16) & 255), dg = g - ((p >> 8) & 255), db = b - (p & 255);
                if (dr * dr + dg * dg + db * db <= tol2) { cand[i] = true; break; }
            }
        }

        bool[] marks = new bool[n];
        var queue = new int[n];
        int head = 0, tail = 0;
        for (int x = 0; x < w; x++)
        {
            Seed(marks, queue, ref tail, cand, x);
            Seed(marks, queue, ref tail, cand, (h - 1) * w + x);
        }
        for (int y = 0; y < h; y++)
        {
            Seed(marks, queue, ref tail, cand, y * w);
            Seed(marks, queue, ref tail, cand, y * w + w - 1);
        }
        while (head < tail)
        {
            int i = queue[head++];
            int y = i / w, x = i % w;
            if (x > 0) Seed(marks, queue, ref tail, cand, i - 1);
            if (x < w - 1) Seed(marks, queue, ref tail, cand, i + 1);
            if (y > 0) Seed(marks, queue, ref tail, cand, i - w);
            if (y < h - 1) Seed(marks, queue, ref tail, cand, i + w);
        }

        int cnt = 0;
        for (int i = 0; i < n; i++) if (marks[i]) { px[i] = 0; cnt++; }
        bg = marks;
        removedFraction = (double)cnt / n;
        return removedFraction >= 0.005 && removedFraction <= 0.995;
    }

    static void Seed(bool[] marks, int[] q, ref int tail, bool[] cand, int i)
    {
        if (cand[i] && !marks[i]) { marks[i] = true; q[tail++] = i; }
    }

    static void RemoveSmallComponents(int[] px, int w, int h)
    {
        int n = w * h;
        int[] label = new int[n];
        for (int i = 0; i < n; i++) label[i] = -1;
        var q = new int[n];
        var sizes = new List<int>();
        int next = 0;

        for (int seed = 0; seed < n; seed++)
        {
            if (((px[seed] >> 24) & 255) == 0 || label[seed] >= 0) continue;
            int head = 0, tail = 0, count = 0;
            q[tail++] = seed; label[seed] = next;
            while (head < tail)
            {
                int i = q[head++]; count++;
                int y = i / w, x = i % w;
                for (int yy = -1; yy <= 1; yy++)
                    for (int xx = -1; xx <= 1; xx++)
                    {
                        if (xx == 0 && yy == 0) continue;
                        int nx = x + xx, ny = y + yy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        int j = ny * w + nx;
                        if (((px[j] >> 24) & 255) == 0 || label[j] >= 0) continue;
                        label[j] = next;
                        q[tail++] = j;
                    }
            }
            sizes.Add(count);
            next++;
        }

        if (sizes.Count <= 1) return;
        int max = 0;
        foreach (int s in sizes) if (s > max) max = s;
        int minKeep = Math.Max(16, (int)(max * 0.002));
        for (int i = 0; i < n; i++)
            if (((px[i] >> 24) & 255) != 0 && sizes[label[i]] < minKeep)
                px[i] = 0;
    }

    static void BleedColor(int[] px, int w, int h, int maxDist)
    {
        int n = w * h;
        int[] depth = new int[n];
        var q = new Queue<int>();
        for (int i = 0; i < n; i++)
            if (((px[i] >> 24) & 255) > 0) depth[i] = -1;

        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * w + x;
                if (depth[i] != 0) continue;
                int src = -1;
                if (x > 0 && depth[i - 1] < 0) src = i - 1;
                else if (x < w - 1 && depth[i + 1] < 0) src = i + 1;
                else if (y > 0 && depth[i - w] < 0) src = i - w;
                else if (y < h - 1 && depth[i + w] < 0) src = i + w;
                if (src < 0) continue;
                px[i] = px[src] & 0x00FFFFFF;
                depth[i] = 1;
                q.Enqueue(i);
            }

        while (q.Count > 0)
        {
            int i = q.Dequeue();
            int d = depth[i];
            if (d >= maxDist) continue;
            int y = i / w, x = i % w;
            for (int k = 0; k < 4; k++)
            {
                int j;
                if (k == 0) { if (x == 0) continue; j = i - 1; }
                else if (k == 1) { if (x == w - 1) continue; j = i + 1; }
                else if (k == 2) { if (y == 0) continue; j = i - w; }
                else { if (y == h - 1) continue; j = i + w; }
                if (depth[j] != 0) continue;
                px[j] = px[i] & 0x00FFFFFF;
                depth[j] = d + 1;
                q.Enqueue(j);
            }
        }
    }

    static void BuildWeights(int srcLen, int dstLen, out int[][] idx, out float[][] wt)
    {
        double scale = (double)srcLen / dstLen;
        double radius = scale > 1.0 ? Math.Max(1.0, scale * 0.5) : 1.0;
        idx = new int[dstLen][];
        wt = new float[dstLen][];
        for (int t = 0; t < dstLen; t++)
        {
            double c = (t + 0.5) * scale - 0.5;
            int lo = (int)Math.Floor(c - radius);
            int hi = (int)Math.Ceiling(c + radius);
            var li = new List<int>();
            var lw = new List<float>();
            double sum = 0;
            for (int j = lo; j <= hi; j++)
            {
                double d = Math.Abs(j - c);
                double w = radius - d;
                if (w <= 0) continue;
                int jj = j;
                if (jj < 0) jj = 0;
                if (jj >= srcLen) jj = srcLen - 1;
                li.Add(jj);
                lw.Add((float)w);
                sum += w;
            }
            if (sum <= 0)
            {
                int jj = Math.Min(srcLen - 1, Math.Max(0, (int)Math.Round(c)));
                li.Add(jj); lw.Add(1f); sum = 1;
            }
            for (int k = 0; k < lw.Count; k++) lw[k] = (float)(lw[k] / sum);
            idx[t] = li.ToArray();
            wt[t] = lw.ToArray();
        }
    }

    static int[] ResamplePremul(int[] src, int sw, int sh, int dw, int dh)
    {
        int[][] hx; float[][] hwt;
        int[][] vy; float[][] vwt;
        BuildWeights(sw, dw, out hx, out hwt);
        BuildWeights(sh, dh, out vy, out vwt);

        int n = sw * sh;
        var pr = new float[n];
        var pg = new float[n];
        var pb = new float[n];
        var pa = new float[n];
        for (int i = 0; i < n; i++)
        {
            int c = src[i];
            float a = ((c >> 24) & 255) / 255f;
            pr[i] = ((c >> 16) & 255) * a;
            pg[i] = ((c >> 8) & 255) * a;
            pb[i] = (c & 255) * a;
            pa[i] = a;
        }

        var hr = new float[dw * sh];
        var hg = new float[dw * sh];
        var hb = new float[dw * sh];
        var ha = new float[dw * sh];
        for (int y = 0; y < sh; y++)
        {
            int sb = y * sw;
            int db = y * dw;
            for (int x = 0; x < dw; x++)
            {
                int[] ix = hx[x];
                float[] w = hwt[x];
                float sr = 0, sg = 0, sbv = 0, sa = 0;
                for (int k = 0; k < ix.Length; k++)
                {
                    int j = sb + ix[k];
                    float wk = w[k];
                    sr += pr[j] * wk;
                    sg += pg[j] * wk;
                    sbv += pb[j] * wk;
                    sa += pa[j] * wk;
                }
                int o = db + x;
                hr[o] = sr; hg[o] = sg; hb[o] = sbv; ha[o] = sa;
            }
        }

        var dst = new int[dw * dh];
        for (int y = 0; y < dh; y++)
        {
            int[] iy = vy[y];
            float[] w = vwt[y];
            int db = y * dw;
            for (int x = 0; x < dw; x++)
            {
                float sr = 0, sg = 0, sbv = 0, sa = 0;
                for (int k = 0; k < iy.Length; k++)
                {
                    int j = iy[k] * dw + x;
                    float wk = w[k];
                    sr += hr[j] * wk;
                    sg += hg[j] * wk;
                    sbv += hb[j] * wk;
                    sa += ha[j] * wk;
                }
                int a = (int)Math.Round(Math.Min(1.0f, Math.Max(0f, sa)) * 255);
                int r = 0, g = 0, b = 0;
                if (sa > 0.0001f)
                {
                    r = (int)Math.Round(sr / sa); if (r < 0) r = 0; if (r > 255) r = 255;
                    g = (int)Math.Round(sg / sa); if (g < 0) g = 0; if (g > 255) g = 255;
                    b = (int)Math.Round(sbv / sa); if (b < 0) b = 0; if (b > 255) b = 255;
                }
                dst[db + x] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        return dst;
    }

    static byte[] RoundedMask(int size, int pad, int content, double radiusFrac)
    {
        const int ss = 8;
        double r = radiusFrac * content;
        if (r < 0.35) r = 0;
        if (r > content / 2.0) r = content / 2.0;

        double x0 = pad, y0 = pad, x1 = pad + content, y1 = pad + content;
        double cxl = x0 + r, cxr = x1 - r, cyt = y0 + r, cyb = y1 - r;
        var mask = new byte[size * size];
        int total = ss * ss;

        for (int py = 0; py < size; py++)
            for (int px = 0; px < size; px++)
            {
                int inside = 0;
                for (int sy = 0; sy < ss; sy++)
                {
                    double y = py + (sy + 0.5) / ss;
                    for (int sx = 0; sx < ss; sx++)
                    {
                        double x = px + (sx + 0.5) / ss;
                        if (x < x0 || x > x1 || y < y0 || y > y1) continue;
                        if (r > 0)
                        {
                            double cx, cy;
                            if (x < cxl) cx = cxl; else if (x > cxr) cx = cxr; else { inside++; continue; }
                            if (y < cyt) cy = cyt; else if (y > cyb) cy = cyb; else { inside++; continue; }
                            double dx = x - cx, dy = y - cy;
                            if (dx * dx + dy * dy > r * r) continue;
                        }
                        inside++;
                    }
                }
                mask[py * size + px] = (byte)Math.Round(inside * 255.0 / total);
            }
        return mask;
    }

    static void WriteIco(string path, int[] sizes, List<int[]> layers)
    {
        var blobs = new byte[sizes.Length][];
        for (int k = 0; k < sizes.Length; k++) blobs[k] = BuildDib(layers[k], sizes[k]);

        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (var bw = new BinaryWriter(fs))
        {
            bw.Write((ushort)0);
            bw.Write((ushort)1);
            bw.Write((ushort)sizes.Length);
            int offset = 6 + 16 * sizes.Length;
            for (int k = 0; k < sizes.Length; k++)
            {
                int s = sizes[k];
                bw.Write((byte)(s == 256 ? 0 : s));
                bw.Write((byte)(s == 256 ? 0 : s));
                bw.Write((byte)0);
                bw.Write((byte)0);
                bw.Write((ushort)1);
                bw.Write((ushort)32);
                bw.Write((uint)blobs[k].Length);
                bw.Write((uint)offset);
                offset += blobs[k].Length;
            }
            foreach (byte[] b in blobs) bw.Write(b);
        }
    }

    static byte[] BuildDib(int[] px, int size)
    {
        int maskStride = ((size + 31) / 32) * 4;
        int xorSize = size * size * 4;
        int andSize = maskStride * size;
        using (var ms = new MemoryStream(40 + xorSize + andSize))
        using (var bw = new BinaryWriter(ms))
        {
            bw.Write(40);
            bw.Write(size);
            bw.Write(size * 2);
            bw.Write((ushort)1);
            bw.Write((ushort)32);
            bw.Write(0);
            bw.Write(xorSize + andSize);
            bw.Write(0);
            bw.Write(0);
            bw.Write(0);
            bw.Write(0);

            for (int y = size - 1; y >= 0; y--)
                for (int x = 0; x < size; x++)
                {
                    int c = px[y * size + x];
                    bw.Write((byte)(c & 255));
                    bw.Write((byte)((c >> 8) & 255));
                    bw.Write((byte)((c >> 16) & 255));
                    bw.Write((byte)((c >> 24) & 255));
                }

            var row = new byte[maskStride];
            for (int y = size - 1; y >= 0; y--)
            {
                Array.Clear(row, 0, row.Length);
                for (int x = 0; x < size; x++)
                {
                    int a = (px[y * size + x] >> 24) & 255;
                    if (a < 128) row[x >> 3] |= (byte)(0x80 >> (x & 7));
                }
                bw.Write(row);
            }
            bw.Flush();
            return ms.ToArray();
        }
    }
}
'@
}

try {
    $result = [Png2IcoEngine]::Run($InputFile, $OutputFile, [int[]]$Sizes,
        $PaddingPercent, $CornerRadiusPercent, $Tolerance, [bool]$ForceKeyBackground, $PreviewDir)
    Write-Host "Done" -ForegroundColor Green
    Write-Host $result
}
catch {
    Write-Host ("Conversion failed: " + $_.Exception.GetBaseException().Message) -ForegroundColor Red
    exit 1
}
