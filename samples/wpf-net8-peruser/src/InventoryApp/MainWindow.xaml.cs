using System.Windows;
using InventoryApp.Core;

namespace InventoryApp;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        StockGrid.ItemsSource = SampleStock.Items;
    }
}
