using System.Drawing;
using System.Windows.Forms;

namespace ClinicDesk
{
    public class MainForm : Form
    {
        public MainForm()
        {
            Text = "Clinic Desk";
            ClientSize = new Size(420, 240);
            var list = new ListBox { Dock = DockStyle.Fill };
            list.Items.AddRange(new object[] { "09:00  A. Rivera", "09:30  K. Osei", "10:15  M. Chen" });
            Controls.Add(list);
        }
    }
}
