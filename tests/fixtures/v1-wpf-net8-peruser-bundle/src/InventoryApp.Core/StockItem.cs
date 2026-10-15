namespace InventoryApp.Core;

public sealed record StockItem(string Sku, string Name, int Quantity)
{
    public bool IsLow => Quantity < 10;
}

public static class SampleStock
{
    public static IReadOnlyList<StockItem> Items { get; } =
    [
        new("CT-1001", "Cable ties (100)", 42),
        new("HX-0420", "Hex bolts M8", 7),
        new("WS-0008", "Washers M8", 120),
    ];
}
