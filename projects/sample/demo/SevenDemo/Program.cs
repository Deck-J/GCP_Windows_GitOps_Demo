using System;

namespace SevenDemo
{
    // Small image-build proof that the pinned .NET SDK and C# language version work.
    internal static class Program
    {
        private static void Main()
        {
            // Tuple syntax and pattern matching demonstrate C# 7 language features.
            var build = (Framework: ".NET 7", Language: "C# 7.0");
            object result = build;

            if (result is ValueTuple<string, string> proof)
            {
                Console.WriteLine("SevenDemo OK | Target={0} | Language={1}", proof.Item1, proof.Item2);
            }
        }
    }
}
