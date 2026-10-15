using InventoryApp.Core;

namespace InventoryApp.Tests;

public class StockItemTests
{
    [Fact]
    public void Below_ten_is_low() => Assert.True(new StockItem("X", "X", 9).IsLow);
}
