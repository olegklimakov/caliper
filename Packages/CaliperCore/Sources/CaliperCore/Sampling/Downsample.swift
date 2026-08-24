/// Reduces a series to the number of points something can actually draw.
///
/// Every chart in this app has this problem: five minutes of one-second samples
/// into twenty-eight points of menu bar width, or a year of hourly buckets into
/// eight hundred pixels. Handing the extra samples to the drawing code costs
/// real time and shows nothing.
public enum Downsample {
    /// Keeps the peak of each bucket rather than its mean.
    ///
    /// A spike that lasted one sample is exactly what a monitor exists to show,
    /// and averaging is what would hide it. Returns the input unchanged when it
    /// already fits.
    public static func peaks(
        of values: some RandomAccessCollection<Double>,
        to count: Int
    ) -> [Double] {
        guard count > 0 else { return [] }
        guard values.count > count else { return Array(values) }

        return (0..<count).map { slot in
            // Proportional slicing rather than a fixed stride, so the last
            // bucket ends exactly at the end of the input and no samples are
            // dropped or counted twice.
            let start = values.index(values.startIndex, offsetBy: values.count * slot / count)
            let end = values.index(values.startIndex, offsetBy: values.count * (slot + 1) / count)
            return values[start..<end].max() ?? 0
        }
    }
}
