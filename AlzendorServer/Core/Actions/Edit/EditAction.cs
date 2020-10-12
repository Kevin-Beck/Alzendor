namespace Alzendor.Server.Core.Actions.Edit
{
    public class EditAction : ActionObject
    {
        public string NewValue { get; set; }
        public string Component { get; set; }
        public string ElementToEdit { get; set; }

        public string Sender { get; set; }

        public EditType TypeOfEdit { get; set; }

        public EditAction(string sender,  EditType type, string element, string componentOfElement, string newValue) : base("Edit", ActionPriority.LOW, ActionType.EDIT)
        {
            Sender = sender;
            TypeOfEdit = type;
            Component = componentOfElement;
            NewValue = newValue;
            ElementToEdit = element;
        }
    }
}
